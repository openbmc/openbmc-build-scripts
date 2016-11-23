#!/usr/bin/env python
#
# Execute the given repository's unit tests
#
import os
import sys
import argparse
#TODO Add :--enable-unpatched-systemd to mapper
KEYS = {'AC_CHECK_LIB:mapper:phosphor-objmgr',
        'AC_CHECK_HEADER:host-ipmid/ipmid-api.h:phosphor-host-ipmid'
       }

# Get workspace directory (package source to be tested)
WORKSPACE = os.environ.get('WORKSPACE')
if WORKSPACE is None:
  print "ERROR: Environment variable 'WORKSPACE' not set"
  sys.exit(-1)

# Determine package name
WORKSPACE_PKG = os.environ.get('WORKSPACE_PKG')
if os.path.exists(WORKSPACE_PKG):
  PKG = os.path.basename(WORKSPACE_PKG)
else:
  print "ERROR: Package workspace directory not found"
  sys.exit(-1)

def build_deps(package=None, packageDir=None, DEPS=None):
  os.chdir(packageDir)
  try:
    # Open configure.ac
    with open("configure.ac","rt") as infile:
      for line in infile:
        # End of file
        if not line:
          break

        # Find new dependency
        for dep in KEYS:
          if (line.startswith(dep.split(":",1)[0])) and (line.find(dep.split(":",1)[1].split(":",1)[0]) != -1):
            if dep.rsplit(":",1)[1] not in DEPS:
              DEPS[dep.rsplit(":",1)[1]] = 0
              pkgRepo = "https://gerrit.openbmc-project.xyz/openbmc/"+dep.rsplit(":",1)[1]
              os.chdir(WORKSPACE)
              os.system("git clone "+pkgRepo)
              DEPS = build_deps(dep.rsplit(":",1)[1], WORKSPACE+dep.rsplit(":",1)[1], DEPS)
            else:
              if DEPS[dep.rsplit(":",1)[1]] == 1:
                continue
              else:
                pkgRepo = "https://gerrit.openbmc-project.xyz/openbmc/"+dep.rsplit(":",1)[1]
                os.chdir(WORKSPACE)
                os.system("git clone "+pkgRepo)
                DEPS = build_deps(dep.rsplit(":",1)[1], WORKSPACE+dep.rsplit(":",1)[1], DEPS)

    # Build & install current package
    infile.close
    if DEPS[package] == 0:
      os.chdir(packageDir)
      #TODO Remove this temp workaround
      if package == "phosphor-objmgr":
        os.system("git fetch https://gerrit.openbmc-project.xyz/openbmc/phosphor-objmgr refs/changes/82/1182/5 && git checkout FETCH_HEAD && ./bootstrap.sh && ./configure --enable-unpatched-systemd && make && make install")
      else:
        os.system("./bootstrap.sh && ./configure && make && make install")
      DEPS[package] = 1
    return DEPS

  except (IOError):
    print "ERROR: Unable to open configure.ac file"

# Determine dependencies and install them
DEPS = dict()
DEPS[PKG] = 0
build_deps(PKG, WORKSPACE_PKG, DEPS)
os.chdir(WORKSPACE_PKG)

# Run package unit tests
os.system("make check")

#TODO Verify each make directive is run, i.e.) `make docs` ?

sys.exit(0)
