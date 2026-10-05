<?php

declare(strict_types=1);

// Example receiver. Terminate public HTTPS at your reverse proxy. Never expose this test server publicly.
header('Content-Type: application/json');
$respond = static function (int $status, string $result): never {
    http_response_code($status);
    echo json_encode(['result' => $result], JSON_THROW_ON_ERROR);
    exit;
};
$secret = getenv('OPENPAY_WEBHOOK_SIGNING_SECRET');
$databasePath = getenv('OPENPAY_WEBHOOK_RECEIVER_DB');
if (! is_string($secret) || strlen($secret) < 32 || ! is_string($databasePath) || $databasePath === '') {
    $respond(503, 'receiver_not_configured');
}
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    $respond(405, 'method_rejected');
}
$timestamp = $_SERVER['HTTP_WEBHOOK_TIMESTAMP'] ?? '';
$eventId = $_SERVER['HTTP_WEBHOOK_ID'] ?? '';
$signature = $_SERVER['HTTP_WEBHOOK_SIGNATURE'] ?? '';
if (! preg_match('/\A[0-9]{1,10}\z/D', $timestamp) || abs(time() - (int) $timestamp) > 300) {
    $respond(401, 'timestamp_rejected');
}
if ((int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > 65536) {
    $respond(413, 'body_too_large');
}
$input = fopen('php://input', 'rb');
$body = $input === false ? false : stream_get_contents($input, 65537);
if (is_resource($input)) {
    fclose($input);
}
if (! is_string($body) || strlen($body) > 65536) {
    $respond(413, 'body_too_large');
}
$expected = 'v1='.hash_hmac('sha256', $timestamp.'.'.$body, $secret);
if (! hash_equals($expected, $signature)) {
    $respond(401, 'signature_rejected');
}
try {
    $payload = json_decode($body, true, 16, JSON_THROW_ON_ERROR);
} catch (JsonException) {
    $respond(400, 'payload_rejected');
}
$uuid = '/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/Di';
if (! is_array($payload) || ($payload['event_id'] ?? null) !== $eventId || ! preg_match($uuid, $eventId)
    || ($payload['type'] ?? null) !== 'wallet.credit_posted'
    || ! is_string($payload['customer_id'] ?? null) || ! preg_match($uuid, $payload['customer_id'])
    || ! is_string($payload['deposit_id'] ?? null) || ! preg_match($uuid, $payload['deposit_id'])
    || ! is_string($payload['currency'] ?? null) || ! preg_match('/\A[A-Z]{3}\z/D', $payload['currency'])
    || ! is_int($payload['amount_minor'] ?? null) || $payload['amount_minor'] <= 0
    || ! is_int($payload['available_minor'] ?? null)
    || ($payload['settlement_status'] ?? null) !== 'unverified') {
    $respond(400, 'payload_rejected');
}
try {
    $database = new PDO('sqlite:'.$databasePath, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $database->exec('PRAGMA busy_timeout = 5000');
    $database->exec('CREATE TABLE IF NOT EXISTS received_wallet_events (event_id TEXT PRIMARY KEY, body_sha256 TEXT NOT NULL)');
    $database->exec('CREATE TABLE IF NOT EXISTS wallet_credit_totals (customer_id TEXT NOT NULL, currency TEXT NOT NULL, amount_minor INTEGER NOT NULL, PRIMARY KEY (customer_id, currency))');
    $database->beginTransaction();
    $insert = $database->prepare('INSERT OR IGNORE INTO received_wallet_events (event_id, body_sha256) VALUES (?, ?)');
    $digest = hash('sha256', $body);
    $insert->execute([$eventId, $digest]);
    $isNew = $insert->rowCount() === 1;
    if ($isNew) {
        // The inbox and consumer change commit together. This is evidence accounting, not verified settlement.
        $apply = $database->prepare('INSERT INTO wallet_credit_totals (customer_id, currency, amount_minor) VALUES (?, ?, ?) ON CONFLICT (customer_id, currency) DO UPDATE SET amount_minor = amount_minor + excluded.amount_minor');
        $apply->execute([$payload['customer_id'], $payload['currency'], $payload['amount_minor']]);
    } else {
        $query = $database->prepare('SELECT body_sha256 FROM received_wallet_events WHERE event_id = ?');
        $query->execute([$eventId]);
        if (! hash_equals((string) $query->fetchColumn(), $digest)) {
            $database->rollBack();
            $respond(409, 'event_conflict');
        }
    }
    $database->commit();
    $respond($isNew ? 202 : 200, $isNew ? 'accepted' : 'duplicate');
} catch (Throwable) {
    if (isset($database) && $database->inTransaction()) {
        $database->rollBack();
    }
    $respond(503, 'receiver_unavailable');
}
