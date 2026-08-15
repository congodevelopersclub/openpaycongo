package main

import (
	"encoding/json"
	"os"

	"github.com/example/wallet-plugin-go/internal/capability"
)

func main() { _ = json.NewEncoder(os.Stdout).Encode(capability.CurrentReport()) }
