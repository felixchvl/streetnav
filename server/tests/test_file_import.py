"""HealthFit file import, without a database: python -m unittest discover -s tests (from server/)."""
import os
import tempfile
import unicodedata
import unittest

from streetnav_server import file_import
from streetnav_server.bronze import RawPart

GPX = ('<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>'
       '<trkpt lat="48.85" lon="2.35"><ele>35</ele><time>2026-10-29T08:00:00Z</time></trkpt>'
       '<trkpt lat="48.86" lon="2.35"><ele>36</ele><time>2026-10-29T08:05:00Z</time></trkpt>'
       '</trkseg></trk></gpx>')


class FileImportTest(unittest.TestCase):
    def test_ids_and_names_do_not_depend_on_unicode_normalization(self):
        # macOS lists "Félix" decomposed (e + combining accent); a copy made with tar may recompose it.
        name = unicodedata.normalize("NFD", "2026-10-29-080000-Vélo (plein air)-Apple Watch de Félix.gpx")
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, name)
            with open(path, "w") as f:
                f.write(GPX)
            rel = file_import.external_id(root, path)
            self.assertEqual(rel, unicodedata.normalize("NFC", name))
            copy = file_import.parse(rel, {"file": RawPart("file", rel, GPX.encode(), "")})
        self.assertEqual((copy.name, copy.device), ("Vélo (plein air)", "Apple Watch de Félix"))
        self.assertEqual((copy.external_id, len(copy.points), copy.duration_s), (rel, 2, 300))


if __name__ == "__main__":
    unittest.main()
