#!/usr/bin/env python3
"""Focused reviewed-animation metadata refusals; no image decoding or GUI."""
from publication_check import validate_gif


HEADER = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff"
IMAGE = b"\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00"
LOOP = b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00"
CONTROL = b"\x21\xf9\x04\x08\x12\x00\x00\x00"


def refused(data):
    try:
        validate_gif(data)
    except ValueError:
        return
    raise AssertionError("unreviewed/malformed GIF accepted")


def main():
    assert validate_gif(HEADER + IMAGE + b"\x3b") == {"width": 1, "height": 1, "frames": 1}
    assert validate_gif(HEADER + LOOP + CONTROL + IMAGE + CONTROL + IMAGE + b"\x3b")["frames"] == 2
    refused(HEADER + b"\x21\xfe\x07comment\x00" + IMAGE + b"\x3b")
    refused(HEADER + b"\x21\x01\x00" + IMAGE + b"\x3b")
    refused(HEADER + LOOP.replace(b"NETSCAPE2.0", b"XMP DataXMP") + IMAGE + b"\x3b")
    refused(HEADER + LOOP + LOOP + IMAGE + b"\x3b")
    refused(HEADER + IMAGE + b"\x3bextra")
    refused(HEADER + IMAGE)
    refused(HEADER + IMAGE * 121 + b"\x3b")
    refused(HEADER[:6] + b"\xff\xff\xff\xff" + HEADER[10:] + IMAGE + b"\x3b")
    for length in range(len(HEADER + LOOP + CONTROL + IMAGE + b"\x3b")):
        refused((HEADER + LOOP + CONTROL + IMAGE + b"\x3b")[:length])
    print("PASS publication GIF: normal frames/loop, metadata refusals, dimensions, frame cap, trailer and truncations")


if __name__ == "__main__":
    main()
