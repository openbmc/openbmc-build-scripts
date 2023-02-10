from gitlint.rules import CommitRule, RuleViolation

class SignedOffBy(CommitRule):
    """ This rule will enforce that each commit contains a "Signed-off-by" line.
    We keep things simple here and just check whether the commit body contains a
    line that starts with "Signed-off-by".
    """

    # A rule MUST have a human friendly name
    name = "body-requires-signed-off-by"

    # A rule MUST have a *unique* id, we recommend starting with UC
    # (for User-defined Commit-rule).
    id = "UC2"

    def validate(self, commit):
        self.log.debug("SignedOffBy: This will be visible when running `gitlint --debug`")

        for line in commit.message.body:
            if line.startswith("Signed-off-by"):
                return

        msg = "Body does not contain a 'Signed-off-by' line"
        return [RuleViolation(self.id, msg, line_nr=1)]
