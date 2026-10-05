<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('operator_sms_pattern_releases', function (Blueprint $table): void {
            $table->char('parser_release_digest', 64)->nullable();
        });

        DB::table('operator_sms_pattern_releases')->orderBy('id')->chunkById(100, static function ($releases): void {
            foreach ($releases as $release) {
                $fields = json_decode($release->encoded_release, true);
                if (! is_array($fields)
                    || ($fields['schema_version'] ?? null) !== '1'
                    || ! is_string($fields['provider'] ?? null)
                    || ! is_string($fields['sender'] ?? null)
                    || ! is_string($fields['template'] ?? null)
                    || ! is_int($fields['pattern_version'] ?? null)
                    || ! is_string($fields['approved_at'] ?? null)
                    || ! is_string($fields['expires_at'] ?? null)) {
                    continue;
                }

                $transcript = '';
                foreach ([
                    'openpaycongo/operator-payment-pattern',
                    $fields['schema_version'],
                    $fields['provider'],
                    $fields['sender'],
                    $fields['template'],
                    (string) $fields['pattern_version'],
                    $fields['approved_at'],
                    $fields['expires_at'],
                ] as $part) {
                    $transcript .= pack('n', strlen($part)).$part;
                }

                DB::table('operator_sms_pattern_releases')->where('id', $release->id)->update([
                    'parser_release_digest' => hash('sha256', $transcript),
                ]);
            }
        });

        Schema::table('operator_sms_pattern_releases', function (Blueprint $table): void {
            $table->unique(['organization_id', 'parser_release_digest'], 'operator_sms_parser_digest_tenant_unique');
        });
    }

    public function down(): void
    {
        Schema::table('operator_sms_pattern_releases', function (Blueprint $table): void {
            $table->dropUnique('operator_sms_parser_digest_tenant_unique');
            $table->dropColumn('parser_release_digest');
        });
    }
};
