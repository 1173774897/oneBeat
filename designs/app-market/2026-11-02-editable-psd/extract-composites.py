#!/usr/bin/env python3
"""Decode the existing PSD composite cache without rewriting any source layers."""
import json
import struct
from pathlib import Path
from PIL import Image
from preserve_psd import parse_psd

ROOT = Path(__file__).resolve().parent


def unpack_row(data, expected):
    result = bytearray()
    pos = 0
    while pos < len(data):
        n = data[pos]
        pos += 1
        if n <= 127:
            result.extend(data[pos:pos+n+1])
            pos += n+1
        elif n >= 129:
            result.extend(data[pos:pos+1] * (257-n))
            pos += 1
    if len(result) != expected:
        raise ValueError('Invalid PackBits composite row length')
    return result


def main():
    layout = json.loads((ROOT / 'layout.json').read_text())
    source_dir = Path(layout['sourcePsdDirectory'])
    for page in layout['pages']:
        source = source_dir / (page['id'] + '.psd')
        data = source.read_bytes()
        info = parse_psd(data)
        head = info['header']
        w, h, channels = head['width'], head['height'], head['channels']
        pos = info['composite']['start']
        compression = struct.unpack_from('>H', data, pos)[0]
        pos += 2
        if compression != 1:
            raise ValueError('The source PSD composite must use PackBits RLE')
        count = h * channels
        lengths = struct.unpack_from('>' + 'H'*count, data, pos)
        pos += count * 2
        planes = []
        for channel in range(channels):
            plane = bytearray()
            for y in range(h):
                size = lengths[channel*h+y]
                plane.extend(unpack_row(data[pos:pos+size], w))
                pos += size
            planes.append(Image.frombytes('L', (w,h), bytes(plane)))
        assert pos == len(data), 'Unexpected trailing composite bytes'
        destination = ROOT / page['source']
        destination.parent.mkdir(parents=True, exist_ok=True)
        Image.merge('RGBA' if channels == 4 else 'RGB', planes).save(destination)
        print(destination.name, 'decoded')


if __name__ == '__main__':
    main()
