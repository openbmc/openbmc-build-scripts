import re

from gitlint.rules import CommitRule, RuleViolation

# These are individuals, by email address, who chose to go by a one-word name.
allowed_singlename_emails = ["anthonyhkf@google.com"]


class BadSignedOffBy(CommitRule):
    name = "bad-signed-off-by"
    id = "UC3"

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
                and match.group(2) not in allowed_singlename_emails
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


class BadAuthoredBy(CommitRule):
    name = "bad-authored-by"
    id = "UC4"

    def validate(self, commit):
        if commit.author_email in allowed_singlename_emails:
            return None

        if len(commit.author_name.split()) <= 1:
            return [
                RuleViolation(
                    self.id,
                    "Author user has too few words; likely user id instead of legal name?",
                    commit.author_name,
                )
            ]

        return None
