import re

from gitlint.options import IntOption
from gitlint.rules import CommitRule, RuleViolation


class BodyMaxLineLengthWithExceptions(CommitRule):
    name = "body-max-line-length-with-exceptions"
    id = "UC1"

    options_spec = [IntOption("line-length", 80, "Max line length")]
    line_length_violation_message = """Line exceeds max length ({0}>{1}).
    It's possible you intended to use one of the following exceptions:
    1. Put logs or shell script in a quoted section with triple quotes (''')
        before and after the section
    2. Put a long link at the bottom in a footnote.
        example: [1] https://my_long_link.com
    Line that was too long:
"""
    tabs_violation_message = "Line contains hard tab characters (\\t)"

    def validate(self, commit):
        in_block_comment = False
        for line in commit.message.body:
            # allow a quoted string to be over the line limit
            if (
                line.startswith("'''")
                or line.startswith('"""')
                or line.startswith("```")
            ):
                in_block_comment = not in_block_comment

            if in_block_comment:
                continue

            if "\t" in line:
                return [
                    RuleViolation(self.id, self.tabs_violation_message, line)
                ]

            # allow footnote url links to be as long as needed example
            # [1] http://www.myspace.com
            ret = re.match(r"^\[\d+\]:? ", line)
            if ret is not None:
                continue

            # allow signed-off-by
            if line.startswith("Signed-off-by:"):
                continue

            max_length = self.options["line-length"].value
            if len(line) > max_length:
                return [
                    RuleViolation(
                        self.id,
                        self.line_length_violation_message.format(
                            len(line), max_length
                        ),
                        line,
                    )
                ]
        return None
