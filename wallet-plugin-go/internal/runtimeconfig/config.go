package runtimeconfig

import (
	"errors"
	"fmt"
	"net"
	"path"
	"strconv"
	"strings"
)

const (
	defaultListenAddress   = ":8080"
	defaultSQLitePath      = "/data/wallet.db"
	defaultBuildVersion    = "dev"
	defaultContractVersion = "unimplemented"
	maximumMetadataLength  = 128
)

var ErrInvalidConfiguration = errors.New("invalid runtime configuration")

type Environment interface {
	LookupEnv(string) (string, bool)
}

type Config struct {
	ListenAddress   string
	SQLitePath      string
	BuildVersion    string
	ContractVersion string
}

func Load(environment Environment) (Config, error) {
	if environment == nil {
		return Config{}, fmt.Errorf("%w: environment", ErrInvalidConfiguration)
	}

	config := Config{
		ListenAddress:   valueOrDefault(environment, "WALLET_LISTEN_ADDRESS", defaultListenAddress),
		SQLitePath:      valueOrDefault(environment, "WALLET_SQLITE_PATH", defaultSQLitePath),
		BuildVersion:    valueOrDefault(environment, "WALLET_BUILD_VERSION", defaultBuildVersion),
		ContractVersion: valueOrDefault(environment, "WALLET_CONTRACT_VERSION", defaultContractVersion),
	}
	if err := validateListenAddress(config.ListenAddress); err != nil {
		return Config{}, err
	}
	if err := validateSQLitePath(config.SQLitePath); err != nil {
		return Config{}, err
	}
	if !isBoundedMetadata(config.BuildVersion) || !isBoundedMetadata(config.ContractVersion) {
		return Config{}, fmt.Errorf("%w: version metadata", ErrInvalidConfiguration)
	}
	return config, nil
}

func valueOrDefault(environment Environment, key, fallback string) string {
	if value, ok := environment.LookupEnv(key); ok {
		return value
	}
	return fallback
}

func validateListenAddress(address string) error {
	if strings.TrimSpace(address) != address || address == "" || strings.ContainsAny(address, "\r\n") {
		return fmt.Errorf("%w: listen address", ErrInvalidConfiguration)
	}
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("%w: listen address", ErrInvalidConfiguration)
	}
	value, err := strconv.ParseUint(port, 10, 16)
	if err != nil || value == 0 {
		return fmt.Errorf("%w: listen address", ErrInvalidConfiguration)
	}
	return nil
}

func validateSQLitePath(sqlitePath string) error {
	if sqlitePath == "" || !path.IsAbs(sqlitePath) || path.Clean(sqlitePath) != sqlitePath || (sqlitePath != "/data" && !strings.HasPrefix(sqlitePath, "/data/")) {
		return fmt.Errorf("%w: sqlite path", ErrInvalidConfiguration)
	}
	return nil
}

func isBoundedMetadata(value string) bool {
	if value == "" || len(value) > maximumMetadataLength {
		return false
	}
	for _, character := range value {
		if character < 0x21 || character > 0x7e {
			return false
		}
	}
	return true
}
