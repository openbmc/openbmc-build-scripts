import re

from gitlint.rules import CommitRule, RuleViolation


class BadSignedOffBy(CommitRule):
    name = "bad-signed-off-by"
    id = "UC3"

    # These are individuals, by email address, who chose to go by a one-word name.
    exceptions = ["anthonyhkf@google.com"]

    def validate(self, commit):
        violations = []

        sobs = [
            x for x in commit.message.body if x.startswith("Signed-off-by:")
        ]
        for sob in sobs:
            match = re.search("Signed-off-by: (.*) <(.*)>", sob)
            if not match:
                violations.append(
                    RuleViolation(self.id, "Invalid Signed-off-by format", sob)
                )
                continue

            if (
                len(match.group(1).split()) <= 1
                and match.group(2) not in self.exceptions
            ):
                violations.append(
                    RuleViolation(
                        self.id,
                        "Signed-off-by user has too few words; likely user id instead of legal name?",
                        sob,
                    )
                )
                continue

        return violations
