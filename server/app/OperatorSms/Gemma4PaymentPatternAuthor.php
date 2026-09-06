<?php

declare(strict_types=1);

namespace App\OperatorSms;

use Illuminate\Http\Client\Factory as HttpFactory;
use JsonException;
use RuntimeException;

/**
 * Minimal, server-side Gemma 4 integration for proposing a deterministic SMS
 * template. The result is always review-only; it cannot alter live parsing.
 */
final class Gemma4PaymentPatternAuthor
{
    public function __construct(private readonly HttpFactory $http) {}

    public function propose(OperatorPaymentPatternSubmission $submission): OperatorPaymentPatternCandidate
    {
        $privateInferenceUrl = config('services.gemma.private_inference_url');
        $authToken = config('services.gemma.auth_token');
        $model = config('services.gemma.model');
        $timeout = config('services.gemma.timeout_seconds');

        if (is_string($privateInferenceUrl) === false || $this->isPrivateInferenceUrl($privateInferenceUrl) === false
            || is_string($authToken) === false || trim($authToken) === ''
            || is_string($model) === false || preg_match('/^gemma-4-[a-z0-9-]+$/', $model) !== 1
            || is_int($timeout) === false || $timeout < 1 || $timeout > 60) {
            throw new RuntimeException('gemma_pattern_author_unavailable');
        }

        $response = $this->http
            ->acceptJson()
            ->withToken($authToken)
            ->timeout($timeout)
            ->post($privateInferenceUrl, [
                'model' => $model,
                'messages' => [
                    [
                        'role' => 'system',
                        'content' => 'Return exactly one JSON object with provider, sender, and template. '
                            .'Template must contain {amount}, {currency}, and {reference}. '
                            .'This is a review-only candidate, never an approval.',
                    ],
                    [
                        'role' => 'user',
                        'content' => "Provider: {$submission->provider}\n"
                            ."Sender: {$submission->sender}\n"
                            ."Payment SMS: {$submission->body}",
                    ],
                ],
                'temperature' => 0,
                'max_tokens' => 512,
                'response_format' => ['type' => 'json_object'],
            ]);

        if ($response->failed()) {
            throw new RuntimeException('gemma_pattern_author_unavailable');
        }

        $text = data_get($response->json(), 'choices.0.message.content');
        if (is_string($text) === false || strlen($text) > 4096) {
            throw new RuntimeException('gemma_pattern_candidate_invalid');
        }

        try {
            $candidate = json_decode($text, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException) {
            throw new RuntimeException('gemma_pattern_candidate_invalid');
        }

        if (is_array($candidate) === false || count($candidate) !== 3
            || array_diff(array_keys($candidate), ['provider', 'sender', 'template']) !== []
            || is_string($candidate['provider']) === false || is_string($candidate['sender']) === false || is_string($candidate['template']) === false
            || $candidate['provider'] !== $submission->provider || $candidate['sender'] !== $submission->sender
            || $this->validTemplate($candidate['template']) === false) {
            throw new RuntimeException('gemma_pattern_candidate_invalid');
        }

        return new OperatorPaymentPatternCandidate(
            provider: $candidate['provider'],
            sender: $candidate['sender'],
            template: $candidate['template'],
        );
    }

    private function validTemplate(string $template): bool
    {
        return strlen($template) <= 512
            && substr_count($template, '{amount}') === 1
            && substr_count($template, '{currency}') === 1
            && substr_count($template, '{reference}') === 1;
    }

    private function isPrivateInferenceUrl(string $url): bool
    {
        $parts = parse_url($url);
        if (is_array($parts) === false
            || ! isset($parts['scheme'], $parts['host'])
            || ! in_array($parts['scheme'], ['http', 'https'], true)) {
            return false;
        }

        $host = strtolower($parts['host']);

        return $host === 'localhost'
            || str_ends_with($host, '.internal')
            || (filter_var($host, FILTER_VALIDATE_IP) !== false
                && filter_var($host, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) === false);
    }
}
