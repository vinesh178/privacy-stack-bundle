package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/vinesh178/privacy-stack-bundle/internal/catalog"
	"github.com/vinesh178/privacy-stack-bundle/internal/installer"
	"github.com/vinesh178/privacy-stack-bundle/internal/planner"
)

const usage = `runctl — install the curated privacy stack

Usage:
  runctl catalog list
  runctl catalog validate
  runctl plan privacy-stack [--domain HOST] [--profiles LIST] [--json]
  sudo runctl install privacy-stack --non-interactive [--domain HOST] [--profiles LIST]
  sudo runctl status

Run a plan before install to preview every operation.`

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		fmt.Fprintln(stdout, usage)
		return nil
	}
	switch args[0] {
	case "catalog":
		root, err := repositoryRoot()
		if err != nil {
			return err
		}
		return runCatalog(args[1:], root, stdout)
	case "plan":
		root, err := repositoryRoot()
		if err != nil {
			return err
		}
		return runPlan(args[1:], root, stdout)
	case "install":
		root, err := repositoryRoot()
		if err != nil {
			return err
		}
		return runInstall(ctx, args[1:], root, stdout)
	case "status":
		return runStatus(args[1:], stdout)
	case "help", "--help", "-h":
		fmt.Fprintln(stdout, usage)
		return nil
	default:
		fmt.Fprintln(stderr, usage)
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func runStatus(args []string, stdout io.Writer) error {
	if len(args) != 0 {
		return errors.New("usage: runctl status")
	}
	receipts, err := installer.ListReceipts("/var/lib/rund/installations")
	if err != nil {
		return err
	}
	if len(receipts) == 0 {
		fmt.Fprintln(stdout, "No installations recorded.")
		return nil
	}
	for _, receipt := range receipts {
		fmt.Fprintf(stdout, "%s\t%s\t%s\t%s\n", receipt.InstanceID, receipt.Version, observeInstallation(receipt), receipt.InstalledAt.Format("2006-01-02 15:04 UTC"))
	}
	return nil
}

func observeInstallation(receipt installer.Receipt) string {
	compose := filepath.Join(receipt.RepositoryRoot, "docker-compose.yml")
	command := exec.Command("docker", "compose", "-f", compose, "ps", "--status", "running", "--services")
	output, err := command.Output()
	if err != nil {
		return "status-unavailable"
	}
	if strings.TrimSpace(string(output)) == "" {
		return "stopped"
	}
	return "running"
}

func runCatalog(args []string, root string, stdout io.Writer) error {
	if len(args) != 1 {
		return errors.New("usage: runctl catalog list|validate")
	}
	apps, err := loadCatalog(root)
	if err != nil {
		return err
	}
	switch args[0] {
	case "list":
		for _, app := range apps {
			fmt.Fprintf(stdout, "%s\t%s\t%s\n", app.Metadata.ID, app.Release.Version, app.Metadata.Name)
		}
	case "validate":
		fmt.Fprintf(stdout, "catalog valid: %d application(s)\n", len(apps))
	default:
		return errors.New("usage: runctl catalog list|validate")
	}
	return nil
}

func runPlan(args []string, root string, stdout io.Writer) error {
	app, plan, jsonOutput, err := parsePlan(args, root)
	if err != nil {
		return err
	}
	if jsonOutput {
		encoder := json.NewEncoder(stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(plan)
	}
	printPlan(stdout, app, plan)
	return nil
}

func runInstall(ctx context.Context, args []string, root string, stdout io.Writer) error {
	app, plan, _, err := parsePlan(args, root)
	if err != nil {
		return err
	}
	if os.Geteuid() != 0 {
		return errors.New("install changes the host and must be run with sudo")
	}
	nonInteractive := slicesContain(args, "--non-interactive")
	if !nonInteractive {
		return errors.New("the MVP install path requires --non-interactive so the deployed configuration matches the plan")
	}
	printPlan(stdout, app, plan)
	fmt.Fprintln(stdout, "\nStarting curated setup...")

	service := installer.Service{
		RepositoryRoot: root,
		StateDir:       "/var/lib/rund/installations",
		Runner:         installer.CommandRunner{},
	}
	receipt, err := service.Install(ctx, app, plan, nonInteractive)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "\nInstalled %s %s. Receipt: %s\n", app.Metadata.Name, receipt.Version, filepath.Join(service.StateDir, receipt.InstanceID+".json"))
	return nil
}

func parsePlan(args []string, root string) (catalog.Application, planner.Plan, bool, error) {
	if len(args) == 0 {
		return catalog.Application{}, planner.Plan{}, false, errors.New("application ID is required")
	}
	applicationID := args[0]
	flags := flag.NewFlagSet("plan", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	domain := flags.String("domain", "", "base domain")
	profiles := flags.String("profiles", "", "comma-separated Compose profiles")
	instance := flags.String("instance", "default", "instance name")
	jsonOutput := flags.Bool("json", false, "print JSON")
	nonInteractive := flags.Bool("non-interactive", false, "run setup without prompts")
	if err := flags.Parse(args[1:]); err != nil {
		return catalog.Application{}, planner.Plan{}, false, err
	}
	_ = nonInteractive

	app, err := loadApplication(root, applicationID)
	if err != nil {
		return catalog.Application{}, planner.Plan{}, false, err
	}
	values := map[string]string{}
	if *domain != "" {
		values["domain"] = *domain
	}
	if *profiles != "" {
		values["profiles"] = *profiles
	}
	plan, err := planner.BuildInstallPlan(app, planner.InstallRequest{Instance: *instance, Values: values})
	return app, plan, *jsonOutput, err
}

func printPlan(output io.Writer, app catalog.Application, plan planner.Plan) {
	fmt.Fprintf(output, "%s %s\nInstance: %s\n\n", app.Metadata.Name, plan.Version, plan.InstanceID)
	for index, operation := range plan.Operations {
		fmt.Fprintf(output, "%d. %-22s %s\n", index+1, operation.Type, operation.Target)
	}
	if len(plan.Configuration) > 0 {
		fmt.Fprintln(output, "\nConfiguration:")
		keys := make([]string, 0, len(plan.Configuration))
		for key := range plan.Configuration {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			fmt.Fprintf(output, "  %s: %s\n", key, plan.Configuration[key])
		}
	}
}

func loadCatalog(root string) ([]catalog.Application, error) {
	paths, err := filepath.Glob(filepath.Join(root, "registry", "apps", "*", "app.yaml"))
	if err != nil {
		return nil, fmt.Errorf("find catalog manifests: %w", err)
	}
	if len(paths) == 0 {
		return nil, errors.New("catalog is empty")
	}
	apps := make([]catalog.Application, 0, len(paths))
	for _, path := range paths {
		app, err := catalog.LoadManifest(path)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		apps = append(apps, app)
	}
	sort.Slice(apps, func(i, j int) bool { return apps[i].Metadata.ID < apps[j].Metadata.ID })
	return apps, nil
}

func loadApplication(root, applicationID string) (catalog.Application, error) {
	path := filepath.Join(root, "registry", "apps", applicationID, "app.yaml")
	app, err := catalog.LoadManifest(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return catalog.Application{}, fmt.Errorf("application %q not found", applicationID)
		}
		return catalog.Application{}, err
	}
	return app, nil
}

func repositoryRoot() (string, error) {
	current, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(current, "registry", "apps")); err == nil {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", errors.New("runctl must be run from the privacy-stack repository")
		}
		current = parent
	}
}

func slicesContain(args []string, value string) bool {
	for _, arg := range args {
		if strings.EqualFold(arg, value) {
			return true
		}
	}
	return false
}
