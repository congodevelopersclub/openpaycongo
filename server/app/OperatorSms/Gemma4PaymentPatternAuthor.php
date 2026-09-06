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
    public function __construct(private readonly HttpFactory $http)
    {
    }

    public function propose(OperatorPaymentPatternSubmission $submission): OperatorPaymentPatternCandidate
    {
        $apiKey = config('services.gemma.api_key');
        $model = config('services.gemma.model');
        $timeout = config('services.gemma.timeout_seconds');

        if (! is_string($apiKey) || trim($apiKey) === ''
            || ! is_string($model) || ! preg_match('/^gemma-4-[a-z0-9-]+$/', $model)
            || ! is_int($timeout) || $timeout < 1 || $timeout > 60) {
            throw new RuntimeException('gemma_pattern_author_unavailable');
        }

        $response = $this->http
            ->acceptJson()
            ->timeout($timeout)
            ->post(
                'https://generativelanguage.googleapis.com/v1beta/models/'.$model.':generateContent?key='.rawurlencode($apiKey),
                [
                    'systemInstruction' => [
                        'parts' => [[
                            'text' => 'Return exactly one JSON object with provider, sender, and template. '
                                .'Template must contain {amount}, {currency}, and {reference}. '
                                .'This is a review-only candidate, never an approval.',
                        ]],
                    ],
                    'contents' => [[
                        'role' => 'user',
                        'parts' => [[
                            'text' => "Provider: {$submission->provider}\n"
                                ."Sender: {$submission->sender}\n"
                                ."Payment SMS: {$submission->body}",
                        ]],
                    ]],
                    'generationConfig' => [
                        'responseMimeType' => 'application/json',
                        'temperature' => 0,
                        'thinkingConfig' => ['thinkingLevel' => 'minimal'],
                    ],
                ],
            );

        if ($response->failed()) {
            throw new RuntimeException('gemma_pattern_author_unavailable');
        }

        $text = data_get($response->json(), 'candidates.0.content.parts.0.text');
        if (! is_string($text) || strlen($text) > 4096) {
            throw new RuntimeException('gemma_pattern_candidate_invalid');
        }

        try {
            $candidate = json_decode($text, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException) {
            throw new RuntimeException('gemma_pattern_candidate_invalid');
        }

        if (! is_array($candidate) || count($candidate) !== 3
            || array_diff(array_keys($candidate), ['provider', 'sender', 'template']) !== []
            || ! is_string($candidate['provider']) || ! is_string($candidate['sender']) || ! is_string($candidate['template'])
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
}
