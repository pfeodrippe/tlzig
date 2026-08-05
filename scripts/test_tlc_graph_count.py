import pathlib
import struct
import tempfile
import unittest

from scripts.tlc_graph_count import INT32_MAX, count_graph


def encode_long_nat(value: int) -> bytes:
    if value <= INT32_MAX:
        return struct.pack(">i", value)
    return struct.pack(">q", -value)


def encode_record(fingerprint: int, tableau: int, pointer: int) -> bytes:
    return (
        struct.pack(">qi", fingerprint, tableau)
        + encode_long_nat(pointer)
    )


class GraphCountTest(unittest.TestCase):
    def test_short_and_long_pointer_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nodes = root / "nodes_0"
            ptrs = root / "ptrs_0"
            with nodes.open("wb") as file:
                file.truncate(INT32_MAX + 4096)
            ptrs.write_bytes(
                encode_record(11, -1, 0)
                + encode_record(12, -1, INT32_MAX)
                + encode_record(13, -1, INT32_MAX + 1)
                + encode_record(14, -1, INT32_MAX + 128)
            )

            self.assertEqual((4, -1, -1, 0, 0), count_graph(ptrs))

    def test_live_partial_record_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nodes = root / "nodes_1"
            ptrs = root / "ptrs_1"
            with nodes.open("wb") as file:
                file.truncate(INT32_MAX + 4096)
            ptrs.write_bytes(
                encode_record(21, 0, INT32_MAX + 1)
                + encode_record(22, 2, INT32_MAX + 256)
                + b"partial"
            )

            self.assertEqual((2, 0, 2, 7, 0), count_graph(ptrs))

    def test_live_partial_short_record_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nodes = root / "nodes_0"
            ptrs = root / "ptrs_0"
            nodes.write_bytes(b"node")
            ptrs.write_bytes(encode_record(31, -1, 0) + b"partial")

            self.assertEqual((1, -1, -1, 7, 0), count_graph(ptrs))

    def test_invalid_complete_pointer_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nodes = root / "nodes_0"
            ptrs = root / "ptrs_0"
            nodes.write_bytes(b"node")
            ptrs.write_bytes(encode_record(41, -1, 4))

            with self.assertRaisesRegex(ValueError, "outside nodes file"):
                count_graph(ptrs)

            self.assertEqual((0, -1, -1, 0, 1), count_graph(ptrs, live=True))


if __name__ == "__main__":
    unittest.main()
