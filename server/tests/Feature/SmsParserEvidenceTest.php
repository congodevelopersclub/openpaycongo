<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Deposits\MobileDepositInput;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use App\Deposits\SubmitMobileDeposit;
use App\Filament\Pages\ManageOperatorSmsPatterns;
use App\Models\Deposit;
use App\Models\OperatorSmsPatternProposal;
use App\Models\OperatorSmsPatternRelease;
use App\Models\Organization;
use App\Models\SourceInstallation;
use App\Models\User;
use App\OperatorSms\OperatorPaymentPatternContract;
use App\OperatorSms\OperatorPaymentPatternReview;
use App\OperatorSms\ReleaseApprovedOperatorPaymentPattern;
use App\Security\FinancialOperatorMfaSession;
use Carbon\CarbonImmutable;
use Filament\Facades\Filament;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Validation\ValidationException;
use Livewire\Livewire;
use LogicException;
use Tests\TestCase;

final class SmsParserEvidenceTest extends TestCase
{
    use RefreshDatabase;

    private const string OrganizationId = '00000000-0000-4000-8000-000000000001';

    private const string WalletTemplate = 'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}';

    private const string LegacyTemplate = 'Paid {amount} {currency}; ref {reference}';

    private User $operator;

    protected function setUp(): void
    {
        parent::setUp();

        (new Organization)->forceFill(['id' => self::OrganizationId])->save();
        $this->operator = User::factory()->create([
            'organization_id' => self::OrganizationId,
            'is_financial_operator' => true,
        ]);
        $this->mock(FinancialOperatorMfaSession::class)
            ->shouldReceive('assertVerified')
            ->zeroOrMoreTimes()
            ->andReturnNull();
        config(['openpay.operator_sms_patterns.signing_secret' => $this->base64Url(str_repeat("\x01", SODIUM_CRYPTO_SIGN_SEEDBYTES))]);
    }

    public function test_parser_evidence_is_required_for_the_sms_path_and_unknown_fields_are_rejected(): void
    {
        $payload = $this->depositPayload();

        try {
            MobileDepositInput::validate($payload, requireParserEvidence: true);
            self::fail('The SMS path accepted a deposit without parser evidence.');
        } catch (ValidationException) {
            self::assertTrue(true);
        }

        self::assertSame($payload, MobileDepositInput::validate($payload));
        $payload['parser_evidence'] = [...$this->evidence(str_repeat('a', 64)), 'raw_sms' => 'must not be accepted'];

        try {
            MobileDepositInput::validate($payload);
            self::fail('Parser evidence accepted an unknown property.');
        } catch (ValidationException) {
            self::assertTrue(true);
        }
    }

    public function test_only_mfa_approved_tenant_release_can_attach_encrypted_wallet_provenance(): void
    {
        $installation = $this->installation();
        $release = $this->approvedWalletRelease();
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence($release->parser_release_digest)];
        $submit = app(SubmitMobileDeposit::class);

        $registered = app(RecordProviderDeposit::class)->registerCustomer($installation->organization_id, $payload['customer_lookup_identifier']);
        $first = $submit->submit($installation, $payload, requireParserEvidence: true);
        $replay = $submit->submit($installation, $payload, requireParserEvidence: true);

        self::assertSame(RecordResult::Recorded, $first->outcome);
        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertSame($registered->id, $first->deposit->customer_id);
        self::assertSame($payload['parser_evidence'], $first->deposit->parser_evidence);
        self::assertNotSame(json_encode($payload['parser_evidence']), $first->deposit->getRawOriginal('parser_evidence'));
        self::assertArrayNotHasKey('parser_evidence', $first->deposit->toArray());

        $reordered = $payload;
        $reordered['parser_evidence'] = array_reverse($payload['parser_evidence'], preserve_keys: true);
        self::assertSame(RecordResult::Replayed, $submit->submit($installation, $reordered, true)->outcome);

        $redelivery = $payload;
        $redelivery['parser_evidence']['sms_received_at'] = CarbonImmutable::parse($payload['parser_evidence']['sms_received_at'])
            ->addSecond()->format('Y-m-d\\TH:i:s\\Z');
        self::assertSame(RecordResult::Replayed, $submit->submit($installation, $redelivery, true)->outcome);
        self::assertSame($payload['parser_evidence'], Deposit::query()->sole()->parser_evidence);
        self::assertDatabaseCount('deposits', 1);
    }

    public function test_manual_proposal_requires_all_wallet_fields_and_signed_release_uses_existing_mfa_parser_authority(): void
    {
        $review = app(OperatorPaymentPatternReview::class);
        $proposal = $review->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate);
        self::assertSame('pending_review', $proposal->status);

        $approved = $review->approve($this->operator, $proposal);
        self::assertSame('approved', $approved->status);
        self::assertSame($this->operator->id, $approved->reviewed_by_user_id);
        self::assertNotNull($approved->reviewed_at);

        $expiresAt = CarbonImmutable::now('UTC')->addDays(30)->startOfSecond();
        $release = app(ReleaseApprovedOperatorPaymentPattern::class)->release($this->operator, $approved, $expiresAt);
        $fields = json_decode($release->encoded_release, true, 16, JSON_THROW_ON_ERROR);
        $transcript = OperatorPaymentPatternContract::transcript($fields);
        $seed = str_repeat("\x01", SODIUM_CRYPTO_SIGN_SEEDBYTES);
        $keypair = sodium_crypto_sign_seed_keypair($seed);

        self::assertSame('1', $fields['schema_version']);
        self::assertSame(['schema_version', 'provider', 'sender', 'template', 'pattern_version', 'approved_at', 'expires_at', 'signature'], array_keys($fields));
        self::assertSame(hash('sha256', $transcript), $release->parser_release_digest);
        self::assertSame(1, $release->pattern_version);
        self::assertSame(32, strlen(sodium_crypto_sign_publickey($keypair)));
        self::assertSame('iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w', $this->base64Url(sodium_crypto_sign_publickey($keypair)));
        self::assertTrue(sodium_crypto_sign_verify_detached($this->decodeBase64Url($fields['signature']), $transcript, sodium_crypto_sign_publickey($keypair)));
        self::assertNotSame(OperatorSmsPatternRelease::query()->sole()->id, $release->parser_release_digest);

        $this->expectException(LogicException::class);
        $approved->forceFill(['template' => self::LegacyTemplate])->save();
    }

    public function test_mfa_and_review_are_required_before_a_release_can_be_issued(): void
    {
        $deniedMfa = \Mockery::mock(FinancialOperatorMfaSession::class);
        $deniedMfa->shouldReceive('assertVerified')->once()->andThrow(new AuthorizationException);
        $this->app->instance(FinancialOperatorMfaSession::class, $deniedMfa);

        try {
            app(OperatorPaymentPatternReview::class)->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate);
            self::fail('A proposal was created without a verified MFA session.');
        } catch (AuthorizationException) {
            self::assertDatabaseCount('operator_sms_pattern_proposals', 0);
        }

        $this->mock(FinancialOperatorMfaSession::class)
            ->shouldReceive('assertVerified')
            ->zeroOrMoreTimes()
            ->andReturnNull();
        $pending = app(OperatorPaymentPatternReview::class)->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate);
        try {
            app(ReleaseApprovedOperatorPaymentPattern::class)->release(
                $this->operator,
                $pending,
                CarbonImmutable::now('UTC')->addDay()->startOfSecond(),
            );
            self::fail('A pending proposal produced a signed release.');
        } catch (AuthorizationException) {
            self::assertDatabaseCount('operator_sms_pattern_releases', 0);
            self::assertSame('pending_review', $pending->fresh()->status);
        }
    }

    public function test_release_selector_distinguishes_unchanged_renewals_and_publishes_the_selected_revision(): void
    {
        Filament::setCurrentPanel(Filament::getPanel('operations'));
        $original = $this->approvedWalletRelease(CarbonImmutable::now('UTC')->addHour()->startOfSecond());
        $originalJson = $original->encoded_release;
        $this->travel(2)->hours();
        $review = app(OperatorPaymentPatternReview::class);
        $renewal = $review->approve($this->operator, $review->proposeManual(
            $this->operator, 'OPERATOR_A', '12345', self::WalletTemplate,
        ));

        Livewire::actingAs($this->operator)
            ->test(ManageOperatorSmsPatterns::class)
            ->mountAction('releasePattern')
            ->assertSee('OPERATOR_A / 12345 / revision 1 /')
            ->assertSee('OPERATOR_A / 12345 / revision 2 /')
            ->callMountedAction(data: [
                'proposal_id' => $renewal->id,
                'expires_at' => CarbonImmutable::now('UTC')->addDay()->format('Y-m-d H:i:s'),
            ])
            ->assertHasNoFormErrors();

        self::assertDatabaseCount('operator_sms_pattern_releases', 2);
        self::assertSame($originalJson, $original->fresh()->encoded_release);
        $renewedRelease = OperatorSmsPatternRelease::query()->where('operator_sms_pattern_proposal_id', $renewal->id)->sole();
        self::assertSame(2, $renewedRelease->pattern_version);
        self::assertTrue($renewedRelease->expires_at->isFuture());
    }

    public function test_an_unchanged_expired_parser_can_be_reproposed_with_fresh_approval(): void
    {
        $approvedAt = CarbonImmutable::parse('2026-10-05T12:00:00Z');
        $this->travelTo($approvedAt);
        $original = $this->approvedWalletRelease($approvedAt->addHour());
        $originalJson = $original->encoded_release;
        $review = app(OperatorPaymentPatternReview::class);
        $publisher = app(ReleaseApprovedOperatorPaymentPattern::class);

        $this->travelTo($approvedAt->addHours(2));
        $renewal = $review->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate);
        self::assertNotSame($original->operator_sms_pattern_proposal_id, $renewal->id);
        self::assertSame('pending_review', $renewal->status);
        self::assertSame(2, $renewal->proposal_revision);
        self::assertNull($renewal->reviewed_at);
        self::assertSame($renewal->id, $review->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate)->id);

        try {
            $publisher->release($this->operator, $renewal, $approvedAt->addDay());
            self::fail('A renewal was published without fresh approval.');
        } catch (AuthorizationException) {
            self::assertDatabaseCount('operator_sms_pattern_releases', 1);
        }

        $approved = $review->approve($this->operator, $renewal);
        $renewed = $publisher->release($this->operator, $approved, $approvedAt->addDay());
        $fields = json_decode($renewed->encoded_release, true, 16, JSON_THROW_ON_ERROR);
        self::assertSame(2, $renewed->pattern_version);
        self::assertSame('2026-10-05T14:00:00Z', $fields['approved_at']);
        self::assertSame($originalJson, $original->fresh()->encoded_release);
        self::assertSame($renewed->id, $publisher->release($this->operator, $approved, $approvedAt->addDays(2))->id);
        self::assertSame($original->id, $publisher->release($this->operator, $original->proposal, $approvedAt->addDays(2))->id);
        self::assertDatabaseCount('operator_sms_pattern_proposals', 2);
        self::assertDatabaseCount('operator_sms_pattern_releases', 2);

        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence($renewed->parser_release_digest)];
        $payload['parser_evidence']['parser_version'] = 2;
        $installation = $this->installation();
        self::assertSame(RecordResult::Recorded, app(SubmitMobileDeposit::class)->submit($installation, $payload, requireParserEvidence: true)->outcome);
        $payload['parser_evidence']['sms_received_at'] = $approvedAt->addHour()->format('Y-m-d\\TH:i:s\\Z');
        $this->expectException(ValidationException::class);
        app(SubmitMobileDeposit::class)->submit($installation, $payload, requireParserEvidence: true);
    }

    public function test_proposal_revision_migration_preserves_existing_records_and_refuses_lossy_rollback(): void
    {
        $migration = require database_path('migrations/2026_10_05_000003_add_operator_sms_pattern_proposal_revisions.php');
        $migration->down();
        $original = OperatorSmsPatternProposal::query()->create([
            'organization_id' => self::OrganizationId,
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => self::WalletTemplate,
            'template_sha256' => hash('sha256', self::WalletTemplate),
            'status' => 'pending_review',
        ]);
        $migration->up();
        self::assertSame(1, $original->fresh()->proposal_revision);

        $review = app(OperatorPaymentPatternReview::class);
        self::assertSame($original->id, $review->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate)->id);
        $review->approve($this->operator, $original->fresh());
        $renewal = $review->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate);
        self::assertSame(2, $renewal->proposal_revision);

        try {
            $migration->down();
            self::fail('Rollback removed a proposal revision.');
        } catch (LogicException) {
            self::assertTrue(Schema::hasColumn('operator_sms_pattern_proposals', 'proposal_revision'));
            self::assertDatabaseCount('operator_sms_pattern_proposals', 2);
        }
    }

    public function test_legacy_three_field_pattern_can_still_be_approved_and_released_but_cannot_back_wallet_evidence(): void
    {
        $proposal = OperatorSmsPatternProposal::query()->create([
            'organization_id' => self::OrganizationId,
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => self::LegacyTemplate,
            'template_sha256' => hash('sha256', self::LegacyTemplate),
            'status' => 'pending_review',
        ]);
        $reviewed = app(OperatorPaymentPatternReview::class)->approve($this->operator, $proposal);
        $legacyRelease = app(ReleaseApprovedOperatorPaymentPattern::class)->release(
            $this->operator,
            $reviewed,
            CarbonImmutable::now('UTC')->addDay()->startOfSecond(),
        );

        self::assertTrue(OperatorPaymentPatternContract::validTemplate(self::LegacyTemplate));
        self::assertFalse(OperatorPaymentPatternContract::validWalletTemplate(self::LegacyTemplate));

        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence($legacyRelease->parser_release_digest)];
        try {
            app(SubmitMobileDeposit::class)->submit($this->installation(), $payload, requireParserEvidence: true);
            self::fail('A legacy three-field pattern was accepted as wallet provenance.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_review_and_release_are_tenant_scoped_and_expired_or_mismatched_capture_evidence_is_rejected(): void
    {
        $otherOrganizationId = '00000000-0000-4000-8000-000000000099';
        (new Organization)->forceFill(['id' => $otherOrganizationId])->save();
        $proposal = OperatorSmsPatternProposal::query()->create([
            'organization_id' => $otherOrganizationId,
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => self::WalletTemplate,
            'template_sha256' => hash('sha256', self::WalletTemplate),
            'status' => 'pending_review',
        ]);

        try {
            app(OperatorPaymentPatternReview::class)->approve($this->operator, $proposal);
            self::fail('A financial operator approved another tenant’s parser proposal.');
        } catch (AuthorizationException) {
            self::assertSame('pending_review', $proposal->fresh()->status);
        }

        $release = $this->approvedWalletRelease(CarbonImmutable::now('UTC')->startOfSecond()->addHour());
        $installation = $this->installation();
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence(
            $release->parser_release_digest,
            CarbonImmutable::now('UTC')->addMinutes(6)->format('Y-m-d\\TH:i:s\\Z'),
        )];
        try {
            app(SubmitMobileDeposit::class)->submit($installation, $payload, true);
            self::fail('A future-dated SMS capture was accepted.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }

        $expiresAt = CarbonImmutable::parse($release->expires_at)->utc();
        $payload['parser_evidence']['sms_received_at'] = $expiresAt->addSecond()->format('Y-m-d\\TH:i:s\\Z');
        $this->travelTo($expiresAt->addSeconds(2));
        try {
            app(SubmitMobileDeposit::class)->submit($installation, $payload, true);
            self::fail('A capture made after the release expired was accepted.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_preapproval_capture_is_rejected_but_a_valid_offline_capture_can_replay_after_expiry(): void
    {
        $approvedAt = CarbonImmutable::parse('2026-10-05T12:00:30Z');
        $this->travelTo($approvedAt->subSeconds(30));
        $proposal = app(OperatorPaymentPatternReview::class)->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate);
        $this->travelTo($approvedAt);
        $approved = app(OperatorPaymentPatternReview::class)->approve($this->operator, $proposal);
        $expiresAt = $approvedAt->addMinute();
        $release = app(ReleaseApprovedOperatorPaymentPattern::class)->release($this->operator, $approved, $expiresAt);
        $installation = $this->installation();
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence(
            $release->parser_release_digest,
            $approvedAt->subSecond()->format('Y-m-d\\TH:i:s\\Z'),
        )];

        try {
            app(SubmitMobileDeposit::class)->submit($installation, $payload, requireParserEvidence: true);
            self::fail('An SMS captured before proposal approval was accepted.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }

        $payload['parser_evidence']['sms_received_at'] = $approvedAt->addSecond()->format('Y-m-d\\TH:i:s\\Z');
        $this->travelTo($approvedAt->addSeconds(2));
        $first = app(SubmitMobileDeposit::class)->submit($installation, $payload, requireParserEvidence: true);
        self::assertSame(RecordResult::Recorded, $first->outcome);

        $this->travelTo($expiresAt->addMinute());
        $replay = app(SubmitMobileDeposit::class)->submit($installation, $payload, requireParserEvidence: true);
        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertDatabaseCount('deposits', 1);
        self::assertSame($payload['parser_evidence'], Deposit::query()->sole()->parser_evidence);
    }

    public function test_release_digest_uniqueness_is_tenant_scoped_and_other_tenant_release_cannot_authorize_ingestion(): void
    {
        $otherOrganizationId = '00000000-0000-4000-8000-000000000098';
        (new Organization)->forceFill(['id' => $otherOrganizationId])->save();
        $otherOperator = User::factory()->create([
            'organization_id' => $otherOrganizationId,
            'is_financial_operator' => true,
        ]);
        $instant = CarbonImmutable::parse('2026-10-05T12:00:00Z');
        $this->travelTo($instant);
        $releaseA = $this->approvedWalletRelease($instant->addDay());
        $proposalB = app(OperatorPaymentPatternReview::class)->proposeManual($otherOperator, 'OPERATOR_A', '12345', self::WalletTemplate);
        $approvedB = app(OperatorPaymentPatternReview::class)->approve($otherOperator, $proposalB);
        $releaseB = app(ReleaseApprovedOperatorPaymentPattern::class)->release($otherOperator, $approvedB, $instant->addDay());

        // Exercise the additive migration against already-issued signed rows, as on an upgrade.
        $digestMigration = require database_path('migrations/2026_09_14_000000_add_parser_release_digest_to_operator_sms_pattern_releases.php');
        $digestMigration->down();
        self::assertFalse(Schema::hasColumn('operator_sms_pattern_releases', 'parser_release_digest'));
        $digestMigration->up();
        $releaseA->refresh();
        $releaseB->refresh();

        self::assertSame($releaseA->parser_release_digest, $releaseB->parser_release_digest);
        self::assertSame(2, OperatorSmsPatternRelease::query()->where('parser_release_digest', $releaseA->parser_release_digest)->count());

        $thirdOrganizationId = '00000000-0000-4000-8000-000000000097';
        (new Organization)->forceFill(['id' => $thirdOrganizationId])->save();
        $thirdOperator = User::factory()->create([
            'organization_id' => $thirdOrganizationId,
            'is_financial_operator' => true,
        ]);
        $thirdTemplate = 'Wallet alert {amount} {currency}; id {reference}; name {customer}; time {occurred_at}';
        $thirdProposal = app(OperatorPaymentPatternReview::class)->proposeManual($thirdOperator, 'OPERATOR_A', '12345', $thirdTemplate);
        $thirdApproved = app(OperatorPaymentPatternReview::class)->approve($thirdOperator, $thirdProposal);
        $thirdRelease = app(ReleaseApprovedOperatorPaymentPattern::class)->release($thirdOperator, $thirdApproved, $instant->addDay());

        $unrelatedInstallation = SourceInstallation::query()->create([
            'organization_id' => self::OrganizationId,
            'installation_digest' => str_repeat('b', 64),
        ]);
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence($thirdRelease->parser_release_digest, $instant->addSecond()->format('Y-m-d\\TH:i:s\\Z'))];
        try {
            app(SubmitMobileDeposit::class)->submit($unrelatedInstallation, $payload, requireParserEvidence: true);
            self::fail('A release owned only by another tenant authorized ingestion.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_ingestion_rechecks_the_persisted_approval_record(): void
    {
        $release = $this->approvedWalletRelease();
        DB::table('operator_sms_pattern_proposals')
            ->where('id', $release->operator_sms_pattern_proposal_id)
            ->update(['status' => 'pending_review']);
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence($release->parser_release_digest)];

        try {
            app(SubmitMobileDeposit::class)->submit($this->installation(), $payload, requireParserEvidence: true);
            self::fail('A release without its persisted MFA-approved review state authorized ingestion.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_mobile_release_endpoint_scopes_results_and_requires_active_read_ability(): void
    {
        $release = $this->approvedWalletRelease();
        $otherOrganizationId = '00000000-0000-4000-8000-000000000096';
        (new Organization)->forceFill(['id' => $otherOrganizationId])->save();
        $otherOperator = User::factory()->create([
            'organization_id' => $otherOrganizationId,
            'is_financial_operator' => true,
        ]);
        $otherProposal = app(OperatorPaymentPatternReview::class)->proposeManual($otherOperator, 'OPERATOR_A', '12345', self::WalletTemplate);
        $otherApproved = app(OperatorPaymentPatternReview::class)->approve($otherOperator, $otherProposal);
        app(ReleaseApprovedOperatorPaymentPattern::class)->release(
            $otherOperator,
            $otherApproved,
            CarbonImmutable::now('UTC')->addDay()->startOfSecond(),
        );

        $installation = $this->installation();
        $readToken = $installation->createToken('parser-release-read', ['mobile:sync:read'])->plainTextToken;
        $this->withToken($readToken)->getJson('/mobile/operator-sms/pattern-releases')
            ->assertOk()
            ->assertExactJson(['releases' => [[
                'release_id' => $release->id,
                'encoded_release' => $release->encoded_release,
            ]]]);

        Auth::forgetGuards();
        $noScopeToken = $installation->createToken('parser-release-no-scope', [])->plainTextToken;
        $this->withToken($noScopeToken)->getJson('/mobile/operator-sms/pattern-releases')->assertForbidden();

        Auth::forgetGuards();
        $installation->forceFill(['revoked_at' => now('UTC')])->save();
        $this->withToken($readToken)->getJson('/mobile/operator-sms/pattern-releases')
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable']);
    }

    private function approvedWalletRelease(?CarbonImmutable $expiresAt = null): OperatorSmsPatternRelease
    {
        $review = app(OperatorPaymentPatternReview::class);
        $proposal = $review->proposeManual($this->operator, 'OPERATOR_A', '12345', self::WalletTemplate);
        $approved = $review->approve($this->operator, $proposal);

        return app(ReleaseApprovedOperatorPaymentPattern::class)->release(
            $this->operator,
            $approved,
            $expiresAt ?? CarbonImmutable::now('UTC')->addDay()->startOfSecond(),
        );
    }

    /** @return array<string, mixed> */
    private function depositPayload(): array
    {
        return [
            'customer_lookup_identifier' => 'customer-001',
            'provider_reference' => 'sms-reference-001',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-10-01T01:00:00Z',
            'sender_identifier' => '12345',
        ];
    }

    /** @return array<string, mixed> */
    private function evidence(string $releaseDigest, ?string $smsReceivedAt = null): array
    {
        return [
            'kind' => 'signed_release',
            'provider' => 'OPERATOR_A',
            'sms_sender' => '12345',
            'parser_version' => 1,
            'sms_received_at' => $smsReceivedAt ?? CarbonImmutable::now('UTC')->startOfSecond()->format('Y-m-d\\TH:i:s\\Z'),
            'evidence_digest' => str_repeat('a', 64),
            'parser_release_id' => $releaseDigest,
        ];
    }

    private function installation(): SourceInstallation
    {
        return SourceInstallation::query()->create([
            'organization_id' => self::OrganizationId,
            'installation_digest' => str_repeat('a', 64),
        ]);
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function decodeBase64Url(string $value): string
    {
        $decoded = base64_decode(strtr($value.str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true);
        self::assertIsString($decoded);

        return $decoded;
    }
}
