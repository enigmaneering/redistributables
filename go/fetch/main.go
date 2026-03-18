package main

import (
	"flag"
	"fmt"
	"os"

	"git.enigmaneering.org/redistributables/go/fetch/gpu"
)

func main() {
	version := flag.String("version", "", "Specific version to download (e.g., v0.0.42). Defaults to latest.")
	dir := flag.String("dir", "external", "Directory to install libraries (default: ./external)")
	help := flag.Bool("help", false, "Show help message")

	flag.Parse()

	if *help {
		fmt.Println("fetch - Download shader compilation toolchain binaries")
		fmt.Println()
		fmt.Println("Usage:")
		fmt.Println("  fetch [flags]")
		fmt.Println()
		fmt.Println("Flags:")
		flag.PrintDefaults()
		fmt.Println()
		fmt.Println("Environment Variables:")
		fmt.Println("  ENIGMATIC_GOFETCH_DIRECTORY - Override installation directory")
		fmt.Println()
		fmt.Println("Examples:")
		fmt.Println("  fetch                    # Install latest version to ./external")
		fmt.Println("  fetch -version v0.0.42   # Install specific version")
		fmt.Println("  fetch -dir /opt/shaders  # Install to custom directory")
		fmt.Println()
		fmt.Println("Freeze Updates:")
		fmt.Println("  Create a 'FREEZE' file in the external directory to prevent")
		fmt.Println("  automatic upgrades when new versions are released.")
		os.Exit(0)
	}

	// Set directory if specified
	if *dir != "external" {
		os.Setenv("ENIGMATIC_GOFETCH_DIRECTORY", *dir)
	}

	var err error
	if *version != "" {
		fmt.Printf("Installing shader compilation toolchain version %s...\n", *version)
		err = gpu.EnsureLibrariesVersion(*version)
	} else {
		fmt.Println("Installing latest shader compilation toolchain...")
		err = gpu.EnsureLibraries()
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println()
	fmt.Println("✓ Shader compilation toolchain installed successfully")
}
