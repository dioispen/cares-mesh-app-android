"""產生器的輸出必須與 docs/ADMIN_NOTICE_V1.md 附錄逐字一致。

Kotlin 與 Dart 的實作照著附錄寫測試，附錄又是這支產生器印出來的；兩者一旦對不上，
就不知道該相信哪一份。共用組包程式碼改動時，這個測試會先發現。
"""

import contextlib
import io
import unittest
from pathlib import Path

import gen_test_vectors

SPEC = Path(__file__).resolve().parents[2] / "docs" / "ADMIN_NOTICE_V1.md"
APPENDIX_START = "### 共用金鑰"


def non_blank_lines(text: str) -> list[str]:
    return [line for line in text.splitlines() if line.strip()]


class GeneratorMatchesSpecAppendixTest(unittest.TestCase):
    def test_output_matches_appendix(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            gen_test_vectors.main()

        spec = SPEC.read_text(encoding="utf-8")
        appendix = spec[spec.index(APPENDIX_START):]
        self.assertEqual(non_blank_lines(appendix), non_blank_lines(out.getvalue()))


if __name__ == "__main__":
    unittest.main()
