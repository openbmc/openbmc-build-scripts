# Jenkins

These are the top level scripts launched by the
[OpenBMC Jenkins instance](https://jenkins.openbmc.org):

| Job                               | Script                          | Notes      |
| --------------------------------- | ------------------------------- | ---------- |
| CI-MISC/ci-build-seed             | jenkins/build-seed              |            |
| CI-MISC/ci-meta                   | jenkins/run-meta-ci             | Deprecated |
| CI-MISC/ci-openbmc-build-scripts  | jenkins/run-build-script-ci     |            |
| CI-MISC/ci-repository-ppc64le     | run-unit-test-docker.sh         |            |
| CI-MISC/openbmc-node-cleaner      | sstate-cache-management.sh      | [1]        |
| CI-MISC/openbmc-userid-validation | jenkins/userid-validation       |            |
| CI-MISC/run-ci-in-qemu            | run-qemu-robot-test.sh          |            |
| ci-openbmc                        | build-setup.sh                  |            |
| ci-repository                     | run-unit-test-docker.sh         |            |
| latest-build-script-changes       | scripts/get_unit_test_report.py |            |
| latest-master                     | build-setup.sh                  |            |
| latest-master-sdk                 | build-setup.sh                  |            |
| latest-qemu-ppc64le               | qemu-build.sh                   |            |
| latest-qemu-x86                   | qemu-build.sh                   |            |
| latest-unit-test-coverage         | scripts/get_unit_test_report.py |            |
| release-tag                       | build-setup.sh                  |            |

[1] Script located
[here](https://github.com/openbmc/openbmc/blob/master/poky/scripts/sstate-cache-management.sh).
