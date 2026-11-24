import math, zlib, struct, os

def png(w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    comp = zlib.compress(raw, 9)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag+data) & 0xFFFFFFFF)
    hdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", hdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")

def draw_chevron(size, gw, gh, stroke, scale=8):
    """模拟 PMChevron：在 canvas 上画 V，返回 RGBA rows"""
    pad = stroke/2 + 0.5
    cw = gw + pad*2
    ch = gh + pad*2
    W = int(cw*scale); H = int(ch*scale)
    # 三个关键点（pointing down：顶点在下）
    x0 = pad;           y0 = pad
    x1 = pad + gw/2;    y1 = pad + gh
    x2 = pad + gw;      y2 = pad

    def dist_to_seg(px, py, ax, ay, bx, by):
        dx, dy = bx-ax, by-ay
        L2 = dx*dx + dy*dy
        if L2 == 0: return math.hypot(px-ax, py-ay)
        t = max(0, min(1, ((px-ax)*dx + (py-ay)*dy)/L2))
        return math.hypot(px-(ax+t*dx), py-(ay+t*dy))

    rows = []
    for j in range(H):
        row = bytearray()
        for i in range(W):
            px = (i+0.5)/scale
            py = (j+0.5)/scale
            d = min(dist_to_seg(px,py,x0,y0,x1,y1), dist_to_seg(px,py,x1,y1,x2,y2))
            if d <= stroke/2 + 0.35:
                a = 255
            elif d <= stroke/2 + 0.85:
                a = int(255 * (1 - (d - stroke/2 - 0.35)/0.5))
            else:
                a = 0
            row += bytes((40, 40, 50, max(0, min(255, a))))
        rows.append(bytes(row))
    return W, H, rows

def compose():
    # 新版
    W1, H1, R1 = draw_chevron(None, 9.5, 2.9, 1.7, 10)
    # 旧版 SF 近似：18x18 的 V，夹角 90，单边 12.7 → 等效 w=18 h=9
    W2, H2, R2 = draw_chevron(None, 18.0, 9.0, 2.6, 10)

    padx = 20
    W = max(W1, W2) + padx*2
    H = H1 + H2 + 80
    rows = []
    for j in range(H):
        row = bytearray()
        for i in range(W):
            # 白底
            row += bytes((255,255,255,255))
        rows.append(row)

    def blit(rows, src, ox, oy, sw, sh):
        for j in range(sh):
            for i in range(sw):
                s = src[j][i*4:i*4+4]
                a = s[3]/255.0
                if a <= 0: continue
                y = oy+j; x = ox+i
                if 0 <= y < len(rows) and 0 <= x < len(rows[0])//4:
                    d = rows[y][x*4:x*4+4]
                    rows[y][x*4+0] = int(d[0]*(1-a)+s[0]*a)
                    rows[y][x*4+1] = int(d[1]*(1-a)+s[1]*a)
                    rows[y][x*4+2] = int(d[2]*(1-a)+s[2]*a)

    blit(rows, R1, padx, 20, W1, H1)
    blit(rows, R2, padx, 20+H1+30, W2, H2)

    out = png(W, H, rows)
    path = r"D:\DeepSeek Harness\projects\plugin-manager\build\chevron_compare.png"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(out)
    print("wrote", path, len(out), "bytes")
    print("新版 9.5x2.9:", "%.1fx%.1f px" % (W1, H1))
    print("旧版 18x9.0:", "%.1fx%.1f px" % (W2, H2))

compose()
