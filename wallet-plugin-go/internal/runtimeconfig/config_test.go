package runtimeconfig

import (
	"errors"
	"testing"
)

type testEnvironment map[string]string

func (env testEnvironment) LookupEnv(key string) (string, bool) {
	value, ok := env[key]
	return value, ok
}

func TestLoadUsesSafeOperationalDefaults(t *testing.T) {
	t.Parallel()

	config, err := Load(testEnvironment{})
	if err != nil {
		t.Fatal(err)
	}
	if config.ListenAddress != ":8080" || config.SQLitePath != "/data/wallet.db" || config.BuildVersion != "dev" || config.ContractVersion != "unimplemented" {
		t.Fatalf("unexpected defaults: %#v", config)
	}
}

func TestLoadRejectsUnsafeOperationalConfiguration(t *testing.T) {
	t.Parallel()

	for name, environment := range map[string]testEnvironment{
		"blank listener":       {"WALLET_LISTEN_ADDRESS": ""},
		"listener without port": {"WALLET_LISTEN_ADDRESS": "127.0.0.1"},
		"relative database":     {"WALLET_SQLITE_PATH": "wallet.db"},
		"database outside data": {"WALLET_SQLITE_PATH": "/tmp/wallet.db"},
		"database traversal":    {"WALLET_SQLITE_PATH": "/data/../wallet.db"},
		"blank build version":   {"WALLET_BUILD_VERSION": ""},
		"control metadata":      {"WALLET_CONTRACT_VERSION": "v1\nleak"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := Load(environment)
			if !errors.Is(err, ErrInvalidConfiguration) {
				t.Fatalf("Load() error = %v, want ErrInvalidConfiguration", err)
			}
		})
	}
}

func TestLoadAcceptsBoundedNonSecretOperationalOverrides(t *testing.T) {
	t.Parallel()

	config, err := Load(testEnvironment{
		"WALLET_LISTEN_ADDRESS":   "127.0.0.1:18080",
		"WALLET_SQLITE_PATH":      "/data/reference/wallet.db",
		"WALLET_BUILD_VERSION":    "2026.08.15",
		"WALLET_CONTRACT_VERSION": "sales-analytics-v1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if config.ListenAddress != "127.0.0.1:18080" || config.SQLitePath != "/data/reference/wallet.db" || config.BuildVersion != "2026.08.15" || config.ContractVersion != "sales-analytics-v1" {
		t.Fatalf("unexpected override: %#v", config)
	}
}
