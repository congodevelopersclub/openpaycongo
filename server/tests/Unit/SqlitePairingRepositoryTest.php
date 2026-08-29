<?php

declare(strict_types=1);

namespace Tests\Unit;

use App\Pairing\SqlitePairingRepository;
use PDO;
use RuntimeException;
use Tests\TestCase;

final class SqlitePairingRepositoryTest extends TestCase
{
    public function test_tenant_scoped_completion_replays_across_restart_and_admin_activation_is_one_time(): void
    {
        $p = tempnam(sys_get_temp_dir(), 'pairing-');
        $r = new SqlitePairingRepository(new PDO('sqlite:'.$p));
        $r->issue('tenant', 'intent');
        self::assertSame(['device_id' => 'device', 'replayed' => false], $r->complete('tenant', 'intent', 'digest', 'device'));
        unset($r);
        $r = new SqlitePairingRepository(new PDO('sqlite:'.$p));
        self::assertSame(['device_id' => 'device', 'replayed' => true], $r->complete('tenant', 'intent', 'digest', 'device'));
        self::assertSame('active', $r->activate('tenant', 'intent', 'admin'));
        $this->expectException(RuntimeException::class);
        $r->complete('tenant', 'intent', 'changed', 'other');
    }

    public function test_activated_device_sync_replays_and_persists_contiguous_ack(): void
    {
        $p = tempnam(sys_get_temp_dir(), 'sync-');
        $r = new SqlitePairingRepository(new PDO('sqlite:'.$p));
        $r->issue('t', 'i');
        $r->complete('t', 'i', 'd', 'dev');
        $r->activate('t', 'i', 'a');
        $b = [['sequence' => 1, 'event_id' => 'e1', 'payload' => 'x'], ['sequence' => 3, 'event_id' => 'e3', 'payload' => 'x']];
        self::assertSame(['ack' => 1, 'replayed' => false], $r->sync('t', 'dev', 'k', $b));
        unset($r);
        $r = new SqlitePairingRepository(new PDO('sqlite:'.$p));
        self::assertSame(['ack' => 1, 'replayed' => true], $r->sync('t', 'dev', 'k', $b));
    }
}
