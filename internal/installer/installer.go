package installer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/vinesh178/privacy-stack-bundle/internal/catalog"
	"github.com/vinesh178/privacy-stack-bundle/internal/planner"
)

type Runner interface {
	Run(ctx context.Context, environment map[string]string, name string, args ...string) error
}

type CommandRunner struct{}

func (CommandRunner) Run(ctx context.Context, environment map[string]string, name string, args ...string) error {
	command := exec.CommandContext(ctx, name, args...)
	command.Env = os.Environ()
	for key, value := range environment {
		command.Env = append(command.Env, key+"="+value)
	}
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}

type Service struct {
	RepositoryRoot string
	StateDir       string
	Runner         Runner
}

type Receipt struct {
	Application    string    `json:"application"`
	Version        string    `json:"version"`
	InstanceID     string    `json:"instanceId"`
	RepositoryRoot string    `json:"repositoryRoot"`
	Status         string    `json:"status"`
	InstalledAt    time.Time `json:"installedAt"`
}

func ListReceipts(stateDir string) ([]Receipt, error) {
	paths, err := filepath.Glob(filepath.Join(stateDir, "*.json"))
	if err != nil {
		return nil, fmt.Errorf("find installation receipts: %w", err)
	}
	receipts := make([]Receipt, 0, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read installation receipt: %w", err)
		}
		var receipt Receipt
		if err := json.Unmarshal(data, &receipt); err != nil {
			return nil, fmt.Errorf("decode installation receipt %s: %w", path, err)
		}
		receipts = append(receipts, receipt)
	}
	return receipts, nil
}

func (service Service) Install(ctx context.Context, app catalog.Application, plan planner.Plan, nonInteractive bool) (Receipt, error) {
	script, err := service.resolveSetupScript(app.Deployment.SetupScript)
	if err != nil {
		return Receipt{}, err
	}
	if service.Runner == nil {
		return Receipt{}, errors.New("installer runner is required")
	}
	if err := validateMemory(plan.MinimumRAMMB); err != nil {
		return Receipt{}, err
	}
	if _, err := os.Stat(filepath.Join(service.RepositoryRoot, ".env")); err == nil {
		return Receipt{}, errors.New("existing .env detected; the MVP only supports a fresh install to guarantee the plan matches the deployment")
	} else if !errors.Is(err, os.ErrNotExist) {
		return Receipt{}, fmt.Errorf("inspect existing configuration: %w", err)
	}

	args := []string{script}
	if nonInteractive {
		args = append(args, "--non-interactive")
	}
	environment := make(map[string]string)
	for _, field := range app.Configuration {
		if field.Env != "" {
			environment[field.Env] = plan.Configuration[field.Key]
		}
	}
	if err := service.Runner.Run(ctx, environment, "bash", args...); err != nil {
		return Receipt{}, fmt.Errorf("setup failed: %w", err)
	}

	receipt := Receipt{
		Application:    plan.Application,
		Version:        plan.Version,
		InstanceID:     plan.InstanceID,
		RepositoryRoot: service.RepositoryRoot,
		Status:         "installed",
		InstalledAt:    time.Now().UTC(),
	}
	if err := service.writeReceipt(receipt); err != nil {
		return Receipt{}, err
	}
	return receipt, nil
}

func validateMemory(minimumMB int) error {
	if minimumMB == 0 {
		return nil
	}
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return fmt.Errorf("inspect host memory: %w", err)
	}
	var totalKB int
	if _, err := fmt.Sscanf(string(data), "MemTotal: %d kB", &totalKB); err != nil {
		return fmt.Errorf("inspect host memory: %w", err)
	}
	if totalKB/1024 < minimumMB {
		return fmt.Errorf("this preset needs at least 8 GB RAM; choose m7i-flex.large or t3.large")
	}
	return nil
}

func (service Service) resolveSetupScript(relativePath string) (string, error) {
	if relativePath == "" {
		return "", errors.New("application does not define a setup script")
	}
	root, err := filepath.Abs(service.RepositoryRoot)
	if err != nil {
		return "", fmt.Errorf("resolve repository root: %w", err)
	}
	script := filepath.Clean(filepath.Join(root, relativePath))
	if script != root && !strings.HasPrefix(script, root+string(filepath.Separator)) {
		return "", errors.New("setup script must stay within the repository")
	}
	info, err := os.Stat(script)
	if err != nil {
		return "", fmt.Errorf("inspect setup script: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("setup script must be a regular file")
	}
	return script, nil
}

func (service Service) writeReceipt(receipt Receipt) error {
	if err := os.MkdirAll(service.StateDir, 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	data, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return fmt.Errorf("encode installation receipt: %w", err)
	}
	data = append(data, '\n')
	target := filepath.Join(service.StateDir, receipt.InstanceID+".json")
	temporary, err := os.CreateTemp(service.StateDir, ".receipt-*")
	if err != nil {
		return fmt.Errorf("create installation receipt: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("secure installation receipt: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return fmt.Errorf("write installation receipt: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close installation receipt: %w", err)
	}
	if err := os.Rename(temporaryName, target); err != nil {
		return fmt.Errorf("publish installation receipt: %w", err)
	}
	return nil
}
