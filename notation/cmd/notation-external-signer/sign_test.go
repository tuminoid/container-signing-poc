package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadCertificateChainEmpty(t *testing.T) {
	f := filepath.Join(t.TempDir(), "empty.pem")
	if err := os.WriteFile(f, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("EXTERNAL_CERT_CHAIN", f)
	if _, err := readCertificateChain(context.Background()); err == nil {
		t.Fatal("empty certificate chain accepted")
	}
}

func TestRunCommandStderr(t *testing.T) {
	_, err := runCommand("sh", "echo signer broke >&2; exit 3")
	if err == nil || !strings.Contains(err.Error(), "signer broke") {
		t.Fatalf("signer stderr missing from error: %v", err)
	}
	_, err = runCommand("sh", "exit 3")
	if err == nil || err.Error() != "exit status 3" {
		t.Fatalf("silent signer error: %v", err)
	}
}
