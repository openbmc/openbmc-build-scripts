# build-gerrit Script Refactoring Summary

## Overview
The [`build-gerrit`](scripts/build-gerrit) script has been refactored to improve readability and make version updates easier.

## Key Improvements

### 1. **Centralized Configuration Section (Lines 35-77)**
All version-dependent values are now at the top of the script:
- `DOCKER_REG` - Docker registry for base images (defaults to public.ecr.aws/docker/library)
- `GERRIT_VERSION` and `GERRIT_MAJOR_MINOR` - Easy to update for new Gerrit releases
- `JAVA_BASE_IMAGE` - Java container version in one place (uses DOCKER_REG)
- Plugin URLs with clear variable names
- `YOCTO_BRANCHES` array - Add/remove branches in one location

### 2. **Function-Based Architecture**
The script now uses clear, single-purpose functions:
- `prepare_workspace()` - Sets up the build directory
- `generate_dockerfile()` - Creates the Dockerfile with all configurations
- `generate_cron_jobs()` - Dynamically generates cron entries from the branch array
- `build_docker_image()` - Builds the final Docker image

### 3. **Improved Maintainability**
- **Plugin URLs**: All plugin download URLs use variables, making version updates straightforward
- **Yocto Branches**: Adding a new branch only requires adding it to the `YOCTO_BRANCHES` array
- **Comments**: Added clear section headers and inline documentation
- **Consistency**: Fixed typos (e.g., "reccomended" → "recommended")

## How to Update to a New Gerrit Version

1. **Update version variables** (lines 40-41):
   ```bash
   GERRIT_VERSION=${g_vrsn:-3.12.0}  # New version
   GERRIT_MAJOR_MINOR="3.12"         # Update major.minor
   ```

2. **Check plugin compatibility** (lines 49-52):
   - Verify plugin URLs still work with new version
   - Update `GITHUB_PLUGIN_VERSION` if needed
   - Check https://gerrit-ci.gerritforge.com/plugin-manager/ for available plugins

3. **Update Java base image if needed** (line 44):
   ```bash
   JAVA_BASE_IMAGE="eclipse-temurin:21.0.6_11-jdk-noble"
   ```

4. **Add new Yocto branches** (lines 56-69):
   ```bash
   YOCTO_BRANCHES=(
       "master"
       # ... existing branches ...
       "new-branch-name"  # Just add here!
   )
   ```

## Docker Registry Configuration

The script now supports the `DOCKER_REG` environment variable (matching the pattern in [`build-setup.sh`](../build-setup.sh:95)):

```bash
# Use default (public.ecr.aws/docker/library)
./scripts/build-gerrit

# Use Docker Hub
DOCKER_REG=docker.io ./scripts/build-gerrit

# Use Ubuntu ECR path
DOCKER_REG=public.ecr.aws/ubuntu ./scripts/build-gerrit

# Use a custom registry
DOCKER_REG=my-registry.example.com ./scripts/build-gerrit
```

This allows you to:
- Use alternative registries when public.ecr.aws/docker/library is unavailable
- Pull from private registries with pre-cached images
- Work in air-gapped environments with local registries

## Benefits

- **Registry Flexibility**: Easy to switch Docker registries via environment variable
- **Single Source of Truth**: All version info in one configuration section
- **DRY Principle**: Yocto branches defined once, used everywhere
- **Clear Structure**: Functions separate concerns and improve readability
- **Easy Updates**: Version changes require minimal edits in obvious locations
- **Better Documentation**: Clear comments explain what needs updating and why

## Testing

After making changes, test the script:
```bash
./scripts/build-gerrit
```

Or with custom version:
```bash

Or with custom registry:
```bash
DOCKER_REG=docker.io g_vrsn=3.12.0 ./scripts/build-gerrit
```
g_vrsn=3.12.0 ./scripts/build-gerrit