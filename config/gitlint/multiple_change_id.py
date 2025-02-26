from gitlint.rules import CommitRule, RuleViolation


class DuplicateChangeIdEntries(CommitRule):
    name = "duplicate-change-id-entries"
    id = "UC2"

    def validate(self, commit):
        change_ids = [x for x in commit.message.body if x.startswith("Change-Id:")]
        if len(change_ids) > 1:
            return [
                RuleViolation(
                    self.id,
                    "Multiple Change-Ids found in commit message body",
                    change_ids,
                )
            ]

        return None
