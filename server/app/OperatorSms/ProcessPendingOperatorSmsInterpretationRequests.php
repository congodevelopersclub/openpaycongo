<?php

declare(strict_types=1);

namespace App\OperatorSms;

use App\Models\OperatorSmsInterpretationRequest;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use RuntimeException;

/**
 * Processes only deliberately submitted, unexpired evidence. Raw SMS is
 * decrypted only while constructing the private inference request and is
 * never included in exceptions, status fields, or command output.
 */
final class ProcessPendingOperatorSmsInterpretationRequests
{
    private const int FailedRetryDelayHours = 6;

    private const int StalledClaimDelayMinutes = 10;

    public function __construct(
        private readonly OperatorPaymentPatternReview $review,
        private readonly Gemma4PaymentPatternAuthor $author,
    ) {}

    public function execute(int $limit = 25): int
    {
        $limit = max(1, min($limit, 100));
        $now = now('UTC');
        $ids = OperatorSmsInterpretationRequest::query()
            ->where('expires_at', '>', now('UTC'))
            ->where(function ($query) use ($now): void {
                $query->where('analysis_status', 'pending')
                    ->orWhere(function ($query) use ($now): void {
                        $query->where('analysis_status', 'failed')
                            ->where('analysed_at', '<=', $now->copy()->subHours(self::FailedRetryDelayHours));
                    })
                    ->orWhere(function ($query) use ($now): void {
                        $query->where('analysis_status', 'processing')
                            ->where('analysis_started_at', '<=', $now->copy()->subMinutes(self::StalledClaimDelayMinutes));
                    });
            })
            ->whereNotNull('provider')
            ->orderBy('created_at')
            ->limit($limit)
            ->pluck('id');
        $processed = 0;

        foreach ($ids as $id) {
            $request = $this->claim((string) $id);
            if ($request === null) {
                continue;
            }

            try {
                $provider = $request->provider;
                $sender = $request->sender;
                $body = $request->protected_sms_body;
                if (! is_string($provider)) {
                    $this->markFailed($request, 'gemma_pattern_analysis_failed');

                    continue;
                }
                $proposal = $this->review->propose(
                    $request->organization_id,
                    new OperatorPaymentPatternSubmission(
                        sender: $sender,
                        body: $body,
                        provider: $provider,
                    ),
                    $this->author,
                );
                $this->markProposed($request, $proposal->id);
            } catch (RuntimeException $exception) {
                $this->markFailed($request, $exception->getMessage());
            }

            $processed++;
        }

        return $processed;
    }

    private function claim(string $id): ?OperatorSmsInterpretationRequest
    {
        return DB::transaction(function () use ($id): ?OperatorSmsInterpretationRequest {
            $request = OperatorSmsInterpretationRequest::query()->lockForUpdate()->find($id);
            $retryable = $request !== null && ($request->analysis_status === 'pending'
                || ($request->analysis_status === 'failed'
                    && $request->analysed_at !== null
                    && CarbonImmutable::parse($request->analysed_at, 'UTC')
                        ->lessThanOrEqualTo(now('UTC')->subHours(self::FailedRetryDelayHours)))
                || ($request->analysis_status === 'processing'
                    && $request->analysis_started_at !== null
                    && CarbonImmutable::parse($request->analysis_started_at, 'UTC')
                        ->lessThanOrEqualTo(now('UTC')->subMinutes(self::StalledClaimDelayMinutes))));
            if (! $retryable
                || CarbonImmutable::parse($request->expires_at, 'UTC')->isPast()
                || $request->provider === null) {
                return null;
            }

            $request->forceFill([
                'analysis_status' => 'processing',
                'analysis_started_at' => now('UTC'),
                'analysis_error' => null,
            ])->save();

            return $request->refresh();
        });
    }

    private function markProposed(OperatorSmsInterpretationRequest $request, string $proposalId): void
    {
        OperatorSmsInterpretationRequest::query()
            ->whereKey($request->id)
            ->where('analysis_status', 'processing')
            ->update([
                'analysis_status' => 'proposed',
                'operator_sms_pattern_proposal_id' => $proposalId,
                'analysed_at' => now('UTC'),
                'analysis_error' => null,
            ]);
    }

    private function markFailed(OperatorSmsInterpretationRequest $request, string $error): void
    {
        $safeError = in_array($error, ['gemma_pattern_author_unavailable', 'gemma_pattern_candidate_invalid'], true)
            ? $error
            : 'gemma_pattern_analysis_failed';
        OperatorSmsInterpretationRequest::query()
            ->whereKey($request->id)
            ->where('analysis_status', 'processing')
            ->update([
                'analysis_status' => 'failed',
                'analysed_at' => now('UTC'),
                'analysis_error' => $safeError,
            ]);
    }
}
