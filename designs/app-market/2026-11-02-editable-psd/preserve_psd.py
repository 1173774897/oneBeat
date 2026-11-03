#!/usr/bin/env python3
"""Append native PSD layers without re-encoding existing layer or smart-object data.

The input PSD layer records are stored bottom-to-top. ``--additions`` must contain
only the new layers; its records and channels are appended in their stored order.
Both documents must be standard 8-bit RGB PSD files (not PSB). The output keeps
the original header, resources, layer records, channel streams, and global data,
except explicitly replaced thumbnails and the stale document-level Txt2 cache.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
from typing import Any


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, length: int) -> bytes:
        if length < 0 or self.pos + length > len(self.data):
            raise ValueError(f"PSD read exceeds file at {self.pos}, length {length}")
        value = self.data[self.pos:self.pos + length]
        self.pos += length
        return value

    def u16(self) -> int:
        return struct.unpack(">H", self.take(2))[0]

    def i16(self) -> int:
        return struct.unpack(">h", self.take(2))[0]

    def u32(self) -> int:
        return struct.unpack(">I", self.take(4))[0]

    def i32(self) -> int:
        return struct.unpack(">i", self.take(4))[0]

    def section32(self) -> dict[str, int]:
        length_offset = self.pos
        length = self.u32()
        start = self.pos
        self.take(length)
        return {"length_offset": length_offset, "start": start,
                "end": self.pos, "length": length}


def _resource_records(data: bytes, section: dict[str, int]) -> tuple[list[dict], int]:
    r = Reader(data)
    r.pos = section["start"]
    records = []
    while r.pos + 12 <= section["end"]:
        start = r.pos
        signature = r.take(4)
        if signature != b"8BIM":
            r.pos = start
            break
        resource_id = r.u16()
        name_start = r.pos
        name_length = r.take(1)[0]
        name_bytes = r.take(name_length)
        name_size = (name_length + 2) & ~1
        r.take(name_start + name_size - r.pos)
        size_offset = r.pos
        length = r.u32()
        content_start = r.pos
        r.take(length)
        r.take(length % 2)
        if r.pos > section["end"]:
            raise ValueError("Image resource exceeds its parent section")
        records.append({"id": resource_id, "start": start, "end": r.pos,
                        "size_offset": size_offset, "data_start": content_start,
                        "length": length,
                        "name": name_bytes.decode("macroman", errors="replace")})
    return records, r.pos


def _additional_blocks(data: bytes, start: int, end: int, alignment: int) -> tuple[list[dict], int]:
    r = Reader(data)
    r.pos = start
    blocks = []
    while r.pos + 12 <= end:
        block_start = r.pos
        signature = r.take(4)
        if signature not in (b"8BIM", b"8B64"):
            r.pos = block_start
            break
        key = r.take(4).decode("latin1")
        length = r.u32()
        content_start = r.pos
        if content_start + length > end:
            raise ValueError(f"Additional information {key} exceeds its parent")
        r.take(length)
        padding = (-length) % alignment
        if r.pos + padding > end:
            raise ValueError(f"Additional information {key} padding exceeds its parent")
        r.take(padding)
        blocks.append({"key": key, "signature": signature.decode("latin1"),
                       "start": block_start, "end": r.pos,
                       "data_start": content_start, "length": length})
    return blocks, r.pos


def parse_psd(data: bytes) -> dict[str, Any]:
    """Return bounded structural offsets and metadata, without decoding pixel data."""
    r = Reader(data)
    if r.take(4) != b"8BPS":
        raise ValueError("Not a Photoshop document")
    version = r.u16()
    if version != 1:
        raise ValueError("Only standard PSD version 1 is supported; PSB requires 64-bit sections")
    reserved = r.take(6)
    if reserved != bytes(6):
        raise ValueError("Unexpected PSD reserved header bytes")
    channels = r.u16()
    height, width, depth, color_mode = r.u32(), r.u32(), r.u16(), r.u16()
    if depth != 8 or color_mode != 3 or channels not in (3, 4):
        raise ValueError("This preserving merger supports 8-bit RGB/RGBA PSD documents")
    if width <= 0 or height <= 0:
        raise ValueError("Invalid PSD dimensions")
    header = {"version": version, "channels": channels, "width": width,
              "height": height, "depth": depth, "color_mode": color_mode}
    color = r.section32()
    resources = r.section32()
    resources["records"], resources["trailing_start"] = _resource_records(data, resources)
    layer_mask = r.section32()
    composite = {"start": r.pos, "end": len(data), "length": len(data) - r.pos}
    if composite["length"] < 2:
        raise ValueError("Missing composite image data")
    composite["compression"] = struct.unpack_from(">H", data, r.pos)[0]
    r.pos = layer_mask["start"]
    layer_info = r.section32()
    if layer_info["end"] > layer_mask["end"] or layer_info["length"] < 2:
        raise ValueError("Missing or invalid layer information")
    r.pos = layer_info["start"]
    signed_count = r.i16()
    count = abs(signed_count)
    layer_info.update({"signed_count": signed_count, "count": count,
                       "count_offset": layer_info["start"], "records_start": r.pos})
    layers = []
    for index in range(count):
        start = r.pos
        top, left, bottom, right = (r.i32() for _ in range(4))
        channel_count = r.u16()
        if channel_count > 56:
            raise ValueError("Invalid layer channel count")
        layer_channels = [{"id": r.i16(), "length": r.u32()} for _ in range(channel_count)]
        blend_signature = r.take(4)
        if blend_signature != b"8BIM":
            raise ValueError("Invalid layer blending signature")
        blend = r.take(4).decode("latin1")
        opacity, clipping, flags, _filler = r.take(4)
        extra_length = r.u32()
        extra_start = r.pos
        extra_end = extra_start + extra_length
        if extra_end > layer_info["end"]:
            raise ValueError("Layer record exceeds layer information")
        mask = r.section32()
        ranges = r.section32()
        name_start = r.pos
        name_length = r.take(1)[0]
        pascal_name = r.take(name_length).decode("macroman", errors="replace")
        name_size = (name_length + 4) & ~3
        r.take(name_start + name_size - r.pos)
        blocks, tags_end = _additional_blocks(data, r.pos, extra_end, 2)
        name = pascal_name
        layer_id = None
        section_type = None
        for block in blocks:
            position = block["data_start"]
            if block["key"] == "luni" and block["length"] >= 4:
                chars = struct.unpack_from(">I", data, position)[0]
                if chars * 2 > block["length"] - 4:
                    raise ValueError("Invalid Unicode layer name")
                name = data[position + 4:position + 4 + chars * 2].decode("utf-16be", errors="replace")
            elif block["key"] == "lyid" and block["length"] >= 4:
                layer_id = struct.unpack_from(">I", data, position)[0]
            elif block["key"] == "lsct" and block["length"] >= 4:
                section_type = struct.unpack_from(">I", data, position)[0]
        r.pos = extra_end
        layers.append({"index": index, "name": name, "layer_id": layer_id,
                       "start": start, "end": extra_end, "length": extra_end - start,
                       "bounds": {"left": left, "top": top, "right": right, "bottom": bottom},
                       "blend_mode": blend, "opacity": opacity, "clipping": clipping,
                       "flags": flags, "visible": not bool(flags & 2),
                       "section_type": section_type, "mask": mask, "blending_ranges": ranges,
                       "extra_start": extra_start, "extra_end": extra_end,
                       "extra_unparsed_start": tags_end,
                       "additional_info": blocks, "channels": layer_channels})
    layer_info["records_end"] = r.pos
    layer_info["channels_start"] = r.pos
    for layer in layers:
        for channel in layer["channels"]:
            channel["start"] = r.pos
            channel["end"] = r.pos + channel["length"]
            if channel["end"] > layer_info["end"]:
                raise ValueError("Layer channel data exceeds layer information")
            channel["compression"] = r.u16() if channel["length"] >= 2 else None
            r.pos = channel["end"]
    layer_info["channels_end"] = r.pos
    layer_info["padding"] = layer_info["end"] - r.pos
    # PSD permits even alignment; some writers additionally align the section to
    # four bytes. Accept only zero padding so real unparsed channel data is not lost.
    padding = layer_info["padding"]
    if padding < 0 or padding > 3 or any(data[r.pos:layer_info["end"]]):
        raise ValueError(f"Unexpected layer-info tail of {padding} bytes")
    r.pos = layer_info["end"]
    global_mask = r.section32()
    if global_mask["end"] > layer_mask["end"]:
        raise ValueError("Global mask exceeds its parent section")
    global_blocks, global_tail = _additional_blocks(data, r.pos, layer_mask["end"], 4)
    return {"bytes": len(data), "sha256": sha256(data), "header": header,
            "color_mode_data": color, "image_resources": resources,
            "layer_and_mask_info": layer_mask, "layer_info": layer_info,
            "layers": layers, "global_mask": global_mask,
            "global_additional_info": global_blocks,
            "global_unparsed_tail_start": global_tail, "composite": composite}


def inspect_psd(path: str | Path) -> dict[str, Any]:
    """Read a PSD and return JSON-serializable offsets and hashes; never pixel bytes."""
    source = Path(path)
    info = parse_psd(source.read_bytes())
    info["file"] = str(source.resolve())
    return info


def encode_packbits(row: bytes) -> bytes:
    output = bytearray()
    length = len(row)
    index = 0
    while index < length:
        run = 1
        while run < 128 and index + run < length and row[index + run] == row[index]:
            run += 1
        if run >= 3:
            output.extend((257 - run, row[index]))
            index += run
            continue
        literal_start = index
        index += run
        while index < length and index - literal_start < 128:
            run = 1
            while run < 128 and index + run < length and row[index + run] == row[index]:
                run += 1
            if run >= 3:
                break
            index += min(run, 128 - (index - literal_start))
        literal = row[literal_start:index]
        output.append(len(literal) - 1)
        output.extend(literal)
    return bytes(output)


def composite_from_rgba(raw: bytes, header: dict[str, int]) -> bytes:
    """Encode interleaved, straight RGBA cache into the original PSD channel count."""
    width, height, channels = header["width"], header["height"], header["channels"]
    if len(raw) != width * height * 4:
        raise ValueError(f"RGBA cache must contain exactly {width * height * 4} bytes")
    rows = []
    sizes = []
    for channel in range(channels):
        plane = raw[channel::4]
        for y in range(height):
            encoded = encode_packbits(plane[y * width:(y + 1) * width])
            if len(encoded) > 65535:
                raise ValueError("An RLE row is too large for a standard PSD")
            sizes.append(struct.pack(">H", len(encoded)))
            rows.append(encoded)
    return b"\x00\x01" + b"".join(sizes) + b"".join(rows)


def jpeg_dimensions(jpeg: bytes) -> tuple[int, int]:
    if not jpeg.startswith(b"\xff\xd8"):
        raise ValueError("Thumbnail must be a JPEG")
    index = 2
    while index < len(jpeg):
        if jpeg[index] != 0xFF:
            raise ValueError("Malformed JPEG marker")
        while index < len(jpeg) and jpeg[index] == 0xFF:
            index += 1
        marker = jpeg[index]
        index += 1
        if marker in range(0xD0, 0xDA) or marker == 0x01:
            continue
        if index + 2 > len(jpeg):
            break
        length = struct.unpack_from(">H", jpeg, index)[0]
        if length < 2 or index + length > len(jpeg):
            raise ValueError("Malformed JPEG segment")
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if length < 8:
                raise ValueError("Malformed JPEG frame")
            height, width = struct.unpack_from(">HH", jpeg, index + 3)
            return width, height
        if marker in (0xDA, 0xD9):
            break
        index += length
    raise ValueError("JPEG dimensions not found")


def _replace_thumbnails(data: bytes, section: dict, jpeg: bytes | None) -> tuple[bytes, list[dict]]:
    if jpeg is None:
        return data[section["start"]:section["end"]], []
    width, height = jpeg_dimensions(jpeg)
    row_bytes = ((width * 24 + 31) // 32) * 4
    payload = struct.pack(">6I2H", 1, width, height, row_bytes,
                          row_bytes * height, len(jpeg), 24, 1) + jpeg
    result = []
    replaced = []
    cursor = section["start"]
    for resource in section["records"]:
        result.append(data[cursor:resource["start"]])
        if resource["id"] in (1033, 1036):
            new_record = data[resource["start"]:resource["size_offset"]] + struct.pack(">I", len(payload)) + payload
            if len(payload) % 2:
                new_record += b"\x00"
            result.append(new_record)
            replaced.append({"resource_id": resource["id"], "old_length": resource["length"],
                             "new_length": len(payload), "width": width, "height": height,
                             "old_sha256": sha256(data[resource["start"]:resource["end"]]),
                             "new_sha256": sha256(new_record)})
        else:
            result.append(data[resource["start"]:resource["end"]])
        cursor = resource["end"]
    result.append(data[cursor:section["end"]])
    return b"".join(result), replaced


def _retained_global_data(data: bytes, info: dict) -> tuple[bytes, list[dict]]:
    # Txt2 is a document-wide text-engine cache. Keeping the old empty cache can
    # disagree with newly appended TySh layers; Photoshop rebuilds it from them.
    cursor = info["layer_info"]["end"]
    chunks = []
    removed = []
    for block in info["global_additional_info"]:
        if block["key"] != "Txt2":
            continue
        chunks.append(data[cursor:block["start"]])
        removed.append({"key": block["key"], "length": block["length"],
                        "record_length": block["end"] - block["start"],
                        "sha256": sha256(data[block["start"]:block["end"]])})
        cursor = block["end"]
    chunks.append(data[cursor:info["layer_and_mask_info"]["end"]])
    return b"".join(chunks), removed


def merge_psd(original_path: str | Path, additions_path: str | Path, output_path: str | Path,
              composite_rgba_path: str | Path | None = None,
              thumbnail_jpeg_path: str | Path | None = None) -> dict[str, Any]:
    """Merge additions above original layers and save an atomic, verified new PSD."""
    original_path, additions_path, output_path = map(Path, (original_path, additions_path, output_path))
    if output_path.resolve() in (original_path.resolve(), additions_path.resolve()):
        raise ValueError("Output must be a new file, never either input")
    original, additions = original_path.read_bytes(), additions_path.read_bytes()
    old, new = parse_psd(original), parse_psd(additions)
    for key in ("width", "height", "depth", "color_mode"):
        if old["header"][key] != new["header"][key]:
            raise ValueError(f"Original/additions header mismatch: {key}")
    old_ids = {layer["layer_id"] for layer in old["layers"] if layer["layer_id"] is not None}
    new_ids = [layer["layer_id"] for layer in new["layers"] if layer["layer_id"] is not None]
    if len(new_ids) != len(set(new_ids)) or old_ids.intersection(new_ids):
        raise ValueError("Addition layer IDs must be unique and distinct from the original IDs")
    count = old["layer_info"]["count"] + new["layer_info"]["count"]
    if count > 32767:
        raise ValueError("Too many layers for a standard PSD")
    signed_count = -count if old["layer_info"]["signed_count"] < 0 else count
    li = bytearray(struct.pack(">h", signed_count))
    for source, info in ((original, old), (additions, new)):
        section = info["layer_info"]
        li.extend(source[section["records_start"]:section["records_end"]])
    for source, info in ((original, old), (additions, new)):
        section = info["layer_info"]
        li.extend(source[section["channels_start"]:section["channels_end"]])
    if len(li) % 2:
        li.append(0)
    global_data, removed = _retained_global_data(original, old)
    layer_mask = struct.pack(">I", len(li)) + bytes(li) + global_data
    thumbnail = Path(thumbnail_jpeg_path).read_bytes() if thumbnail_jpeg_path else None
    resources, replaced = _replace_thumbnails(original, old["image_resources"], thumbnail)
    if composite_rgba_path:
        composite = composite_from_rgba(Path(composite_rgba_path).read_bytes(), old["header"])
        composite_source = "explicit RGBA cache encoded to original channel count"
    else:
        if old["header"]["channels"] != new["header"]["channels"]:
            raise ValueError("Composite channel counts differ; provide --composite-rgba")
        composite = additions[new["composite"]["start"]:]
        composite_source = "additions PSD merged preview copied verbatim"
    resources_section = old["image_resources"]
    merged = (original[:resources_section["length_offset"]] + struct.pack(">I", len(resources)) + resources +
              original[resources_section["end"]:old["layer_and_mask_info"]["length_offset"]] +
              struct.pack(">I", len(layer_mask)) + layer_mask + composite)
    result = parse_psd(merged)
    if result["layer_info"]["count"] != count:
        raise AssertionError("Merged layer count is wrong")
    layers_report = []
    for index, layer in enumerate(old["layers"]):
        written = result["layers"][index]
        original_record = original[layer["start"]:layer["end"]]
        written_record = merged[written["start"]:written["end"]]
        if original_record != written_record:
            raise AssertionError(f"Original layer record changed: {layer['name']}")
        channel_report = []
        if len(layer["channels"]) != len(written["channels"]):
            raise AssertionError("Original channel count changed")
        for before, after in zip(layer["channels"], written["channels"]):
            source_bytes = original[before["start"]:before["end"]]
            target_bytes = merged[after["start"]:after["end"]]
            if before["id"] != after["id"] or source_bytes != target_bytes:
                raise AssertionError(f"Original channel changed: {layer['name']}")
            channel_report.append({"id": before["id"], "length": len(source_bytes),
                                   "sha256": sha256(source_bytes), "equal": True})
        layers_report.append({"index": index, "name": layer["name"], "layer_id": layer["layer_id"],
                              "record_sha256": sha256(original_record), "record_equal": True,
                              "channels": channel_report})
    global_report = []
    retained = [block for block in old["global_additional_info"] if block["key"] != "Txt2"]
    if len(retained) != len(result["global_additional_info"]):
        raise AssertionError("Unexpected global additional information count")
    for before, after in zip(retained, result["global_additional_info"]):
        source_bytes = original[before["start"]:before["end"]]
        target_bytes = merged[after["start"]:after["end"]]
        if before["key"] != after["key"] or source_bytes != target_bytes:
            raise AssertionError("Original global additional information changed")
        global_report.append({"key": before["key"], "length": before["length"],
                              "sha256": sha256(source_bytes), "equal": True})
    resource_report = []
    if len(resources_section["records"]) != len(result["image_resources"]["records"]):
        raise AssertionError("Image resource count changed")
    for before, after in zip(resources_section["records"], result["image_resources"]["records"]):
        source_bytes = original[before["start"]:before["end"]]
        target_bytes = merged[after["start"]:after["end"]]
        changed_thumbnail = thumbnail is not None and before["id"] in (1033, 1036)
        if before["id"] != after["id"] or (not changed_thumbnail and source_bytes != target_bytes):
            raise AssertionError("An unrelated image resource changed")
        resource_report.append({"id": before["id"], "length": before["length"],
                                "sha256": sha256(source_bytes), "equal": source_bytes == target_bytes,
                                "thumbnail_replaced": changed_thumbnail})
    old_mask = old["global_mask"]
    new_mask = result["global_mask"]
    global_mask_equal = original[old_mask["length_offset"]:old_mask["end"]] == merged[new_mask["length_offset"]:new_mask["end"]]
    if not global_mask_equal or original[:26] != merged[:26]:
        raise AssertionError("Original header or global mask changed")
    report = {"original": str(original_path.resolve()), "additions": str(additions_path.resolve()),
              "output": str(output_path.resolve()), "original_sha256": sha256(original),
              "additions_sha256": sha256(additions), "output_sha256": sha256(merged),
              "original_layer_count": old["layer_info"]["count"],
              "added_layer_count": new["layer_info"]["count"], "output_layer_count": count,
              "stored_layer_order": "original bottom-to-top records followed by additions bottom-to-top records",
              "composite_source": composite_source, "removed_global_text_caches": removed,
              "replaced_thumbnails": replaced, "original_layers": layers_report,
              "original_global_blocks": global_report, "original_resources": resource_report,
              "checks": {"header_byte_identical": True, "all_original_layer_records_byte_identical": True,
                         "all_original_channel_streams_byte_identical": True,
                         "all_retained_global_blocks_byte_identical": True,
                         "global_mask_byte_identical": global_mask_equal,
                         "non_thumbnail_resources_byte_identical": True,
                         "layer_count_sign_preserved": (signed_count < 0) == (old["layer_info"]["signed_count"] < 0),
                         "layer_info_even_padded": len(li) % 2 == 0}}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(output_path.name + f".tmp-{os.getpid()}")
    try:
        temporary.write_bytes(merged)
        os.replace(temporary, output_path)
    finally:
        temporary.unlink(missing_ok=True)
    if sha256(original_path.read_bytes()) != report["original_sha256"]:
        raise AssertionError("Original input changed while merging")
    report_path = output_path.with_suffix(".preservation.json")
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inspect", type=Path, help="Print structural metadata only")
    parser.add_argument("--summary-output", type=Path, help="Write --inspect metadata as JSON")
    parser.add_argument("--original", type=Path)
    parser.add_argument("--additions", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--composite-rgba", type=Path, help="Straight interleaved RGBA raw at full document size")
    parser.add_argument("--thumbnail-jpeg", type=Path, help="Replace existing 1033/1036 thumbnail resources only")
    args = parser.parse_args()
    if args.inspect:
        summary = inspect_psd(args.inspect)
        text = json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
        if args.summary_output:
            args.summary_output.write_text(text, encoding="utf-8")
        else:
            print(text, end="")
        return
    if not all((args.original, args.additions, args.output)):
        parser.error("Use --inspect, or provide --original, --additions and --output")
    report = merge_psd(args.original, args.additions, args.output,
                       args.composite_rgba, args.thumbnail_jpeg)
    print(json.dumps({"output": report["output"], "original_layers": report["original_layer_count"],
                      "added_layers": report["added_layer_count"],
                      "checks": report["checks"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
