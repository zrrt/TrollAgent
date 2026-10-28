// WSClient.mm — 最小 WebSocket 客户端（RFC6455 + permessage-deflate RFC7692）
// v7.1.55：edge-tts v2 实测要求 permessage-deflate（无压缩 iOS URLSessionWebSocketTask 合成阶段被断连 0 音频）
// v7.1.68：传输层重写为 Network.framework C API（nw_connection_*）。
//   根因：NSStream 在 TLS 未完全就绪时 [_out write:] 同步阻塞主线程（CFNetwork 内部等 TLS 完成），
//   表现为日志在 write 后戛然而止 + HUD 界面冻结无法拖动。nw_connection 全异步：
//   state==ready（TLS 已就绪）后才发送握手，主线程永不阻塞。ObjC 类 NWConnection 在 theos SDK 不可用，
//   用 C API（nw_connection_*，编译器确认可用）。
// 实现：nw_connection TLS → HTTP Upgrade（Sec-WebSocket-Key + Sec-WebSocket-Extensions）→
// 帧收发（FIN/RSV/opcode/mask/len）→ RSV1=1 消息 zlib raw inflate → onText/onBinary 回调。

#include <zlib.h>
#include <string.h>
#import <Network/Network.h>
#import "WSClient.h"

@implementation WSClient {
    NSString *_urlString;
    NSDictionary *_headers;
    nw_connection_t _conn;
    NSMutableData *_inBuf;      // 已读但未解析完的字节
    BOOL _handshakeDone;
    BOOL _handshakeSent;        // 握手请求已发送
    BOOL _closed;
    // 帧解析状态机
    uint8_t _msgOpcode;         // 当前消息起始帧 opcode（continuation 交付判定用）
    NSMutableData *_payloadBuf;
    int _inflateWindowBits;
    BOOL _serverDeflate;        // 服务端回 permessage-deflate
    NSString *_pendingHandshake;
    NSMutableArray *_sendQueue; // 握手完成前暂存待发文本
}

- (instancetype)initWithURLString:(NSString *)urlString headers:(NSDictionary *)headers {
    self = [super init];
    if (self) {
        _urlString = urlString;
        _headers = headers ?: @{};
        _inBuf = [NSMutableData data];
        _payloadBuf = [NSMutableData data];
        _inflateWindowBits = 15;
        _sendQueue = [NSMutableArray array];
    }
    return self;
}

- (void)connect {
    NSURL *u = [NSURL URLWithString:_urlString];
    NSString *host = u.host;
    if (host.length == 0) { [self _fail:@"bad url host"]; return; }
    NSNumber *port = u.port ?: @443;

    // 预构握手请求
    // v7.1.73：去掉 Sec-WebSocket-Extensions 硬编码——主 App(URLSession) 实测成功的请求不带扩展头，
    // HUD 带 "permessage-deflate; client_max_window_bits" 收到 HTTP/1.1 400 Bad Request（7.1.71 实测）。
    // 服务器若仍发压缩帧(RSV1=1)，_inflate 保留可解；不发则原始帧直接播放，两头兼容。
    NSString *path = [NSString stringWithFormat:@"%@?%@", u.path, u.query ?: @""];
    unsigned char keyBytes[16];
    for (int i = 0; i < 16; i++) keyBytes[i] = (unsigned char)arc4random_uniform(256);
    NSString *b64Key = [[NSData dataWithBytes:keyBytes length:16] base64EncodedStringWithOptions:0];
    NSMutableString *req = [NSMutableString string];
    [req appendFormat:@"GET %@ HTTP/1.1\r\n", path];
    // v7.1.73：Host 省略标准端口 443（URLSession 成功版不带端口，避免服务器解析差异）
    if (port.intValue == 443) [req appendFormat:@"Host: %@\r\n", host];
    else [req appendFormat:@"Host: %@:%d\r\n", host, port.intValue];
    [req appendFormat:@"Connection: Upgrade\r\nUpgrade: websocket\r\n"];
    [req appendFormat:@"Sec-WebSocket-Key: %@\r\n", b64Key];
    [req appendFormat:@"Sec-WebSocket-Version: 13\r\n"];
    [_headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        [req appendFormat:@"%@: %@\r\n", k, v];
    }];
    [req appendString:@"\r\n"];
    _pendingHandshake = [req copy];
    [self _log:@"connect host=%@ port=%@ req=%luB", host, port, (unsigned long)_pendingHandshake.length];

    // Network.framework C API：secure_tcp = TLS 默认（SNI/证书校验系统处理）
    // 17.5 SDK 签名：nw_parameters_create_secure_tcp(configure_tls_block, configure_tcp_block)
    // 两参均 _Nonnull——传 NULL 可能 create 失败返回 nil → 无任何状态回调（7.1.70 实测：state handler 一次都没触发）
    nw_parameters_configure_protocol_block_t noop = ^(nw_protocol_options_t options) {};
    nw_endpoint_t ep = nw_endpoint_create_host([host UTF8String], [[port stringValue] UTF8String]);
    nw_parameters_t params = nw_parameters_create_secure_tcp(noop, noop);
    _conn = nw_connection_create(ep, params);
    [self _log:@"nw create: ep=%d params=%d conn=%d", ep ? 1 : 0, params ? 1 : 0, _conn ? 1 : 0];
    // 17.5 SDK：receive/send 无 queue 参数，回调走 connection 队列（此处设为主队列）
    nw_connection_set_queue(_conn, dispatch_get_main_queue());
    __weak WSClient *wSelf = self;
    nw_connection_set_state_changed_handler(_conn, ^(nw_connection_state_t state, nw_error_t error) {
        WSClient *s = wSelf;
        if (!s) return;
        [s _log:@"nw state=%d err=%d", (int)state, error ? 1 : 0];
        if (state == nw_connection_state_ready) {
            [s _log:@"nw ready — TLS done, sending handshake"];
            [s _sendRawData:[s->_pendingHandshake dataUsingEncoding:NSUTF8StringEncoding] tag:@"handshake"];
            [s _receiveLoop];
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            if (!s->_closed) [s _fail:@"nw failed/cancelled"];
        }
    });
    nw_connection_start(_conn);
    [self _log:@"nw start called"];

    // 10s 握手超时保护（主线程不阻塞）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WSClient *s = wSelf;
        if (s && !s->_handshakeDone && !s->_closed) [s _fail:@"handshake timeout"];
    });
}

// 接收循环：nw_connection_receive 全异步，数据到达即解析
- (void)_receiveLoop {
    if (_closed || !_conn) return;
    __weak WSClient *wSelf = self;
    nw_connection_receive(_conn, 1, 65536, ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
        WSClient *s = wSelf;
        if (!s || s->_closed) return;
        if (error) { [s _log:@"recv error set"]; [s _fail:@"recv error"]; return; }
        if (content) {
            NSMutableData *d = [NSMutableData data];
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
                [d appendBytes:bytes length:size];
                return true;
            });
            [s _log:@"recv %lu bytes", (unsigned long)d.length];
            [s->_inBuf appendData:d];
            if (!s->_handshakeDone) [s _tryFinishHandshake];
            else [s _processFrames];
        }
        if (is_complete) { [s _fail:@"stream ended"]; return; }
        [s _receiveLoop];
    });
}

#pragma mark - 握手

- (void)_tryFinishHandshake {
    NSRange r = [_inBuf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, _inBuf.length)];
    if (r.location == NSNotFound) {
        if (_inBuf.length > 65536) [self _fail:@"handshake too large"];
        return;
    }
    NSData *headData = [_inBuf subdataWithRange:NSMakeRange(0, r.location + 4)];
    [_inBuf replaceBytesInRange:NSMakeRange(0, r.location + 4) withBytes:NULL length:0];
    NSString *head = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0 || ![lines[0] containsString:@"101"]) {
        [self _fail:[NSString stringWithFormat:@"bad status: %@", lines.firstObject]];
        return;
    }
    _serverDeflate = NO;
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"sec-websocket-extensions:"]) {
            if ([line.lowercaseString containsString:@"permessage-deflate"]) {
                _serverDeflate = YES;
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"server_max_window_bits=(\\d+)" options:0 error:nil];
                NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
                if (m && m.numberOfRanges > 1) {
                    int wb = [line substringWithRange:[m rangeAtIndex:1]].intValue;
                    if (wb >= 9 && wb <= 15) _inflateWindowBits = wb;
                }
            }
        }
    }
    _handshakeDone = YES;
    [self _log:@"handshake 101 OK deflate=%d", _serverDeflate ? 1 : 0];
    if (_inBuf.length > 0) [self _processFrames];
    // 冲刷待发队列
    for (NSString *t in _sendQueue) [self sendText:t];
    [_sendQueue removeAllObjects];
    if (self.onOpen) self.onOpen();
}

#pragma mark - 帧解析（接收）

- (void)_processFrames {
    while (!_closed && _inBuf.length > 0) {
        if (_inBuf.length < 2) return;
        const uint8_t *b = (const uint8_t *)_inBuf.bytes;
        uint8_t b0 = b[0], b1 = b[1];
        uint8_t finRsv = b0;
        // v7.1.88：opcode 在字节0 低4位（FIN/RSV3/OPCODE4）——旧代码取 b1&0x0F 是长度字节，
        // 导致所有接收帧 opcode 全错（binary 帧 0x82 被解析成 0xE=14 → 丢弃，text 帧 0x81 成 0xE
        // → turn.start/end 收不到）→ audioBytes=0 frames=0 的根因。
        uint8_t opcode = b0 & 0x0F;
        BOOL hasMask = (b1 & 0x80) != 0;
        uint64_t len = b1 & 0x7F;
        // v7.1.87：帧级诊断日志（定位音频帧解析/剥离失败）
        [self _log:@"frame recv op=%d len=%llu head=%02x%02x%02x%02x rsv=%02x", opcode, len, b0, b1, (_inBuf.length > 2 ? b[2] : 0), (_inBuf.length > 3 ? b[3] : 0), (finRsv & 0x40)];
        NSUInteger headerLen = 2;
        if (len == 126) {
            if (_inBuf.length < 4) return;
            len = ((uint64_t)b[2] << 8) | b[3];
            headerLen = 4;
        } else if (len == 127) {
            if (_inBuf.length < 10) return;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | b[2 + i];
            headerLen = 10;
        }
        // fix：帧长度上限校验——防恶意 server 声明超大帧导致 dataWithLength 内存暴涨（OOM）。
        // 实际用途（edge-tts 音频帧等）远小于 64MB，此上限不影响正常帧。
        if (len > 64 * 1024 * 1024) {
            [self _fail:@"frame too large"];
            return;
        }
        NSUInteger maskLen = hasMask ? 4 : 0;
        NSUInteger need = headerLen + maskLen + (NSUInteger)len;
        if (_inBuf.length < need) return;
        NSUInteger off = headerLen;
        unsigned char maskKey[4];
        if (hasMask) {
            memcpy(maskKey, b + off, 4);
            off += 4;
        }
        NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)len];
        if (len > 0) {
            memcpy(payload.mutableBytes, b + off, (NSUInteger)len);
            if (hasMask) {
                uint8_t *p = (uint8_t *)payload.mutableBytes;
                for (NSUInteger i = 0; i < len; i++) p[i] ^= maskKey[i & 3];
            }
        }
        [_inBuf replaceBytesInRange:NSMakeRange(0, need) withBytes:NULL length:0];
        // 控制帧
        if (opcode == 0x8) { [self _sendControl:0x8 payload:payload]; [self _fail:@"server closed"]; return; }
        if (opcode == 0x9) { [self _sendControl:0xA payload:payload]; continue; }
        if (opcode == 0xA) continue;
        // 数据帧：text=1 / binary=2 / continuation=0
        if (opcode == 0x1 || opcode == 0x2 || opcode == 0x0) {
            BOOL compressed = (finRsv & 0x40) != 0;
            if (compressed && _serverDeflate) {
                NSData *raw = [self _inflate:payload];
                if (raw) payload = [NSMutableData dataWithData:raw];
                else { [self _fail:@"inflate failed"]; return; }
            }
            BOOL fin = (finRsv & 0x80) != 0;
            if (opcode == 0x1 || opcode == 0x2) {
                _msgOpcode = opcode;
                [_payloadBuf setLength:0];
                [_payloadBuf appendData:payload];
                if (fin) [self _deliverPayloadBuf];
            } else { // continuation
                [_payloadBuf appendData:payload];
                if (fin) [self _deliverPayloadBuf];
            }
        }
    }
}

- (void)_deliverPayloadBuf {
    if (_payloadBuf.length == 0) return;
    if (_msgOpcode == 0x1) {
        NSString *s = [[NSString alloc] initWithData:_payloadBuf encoding:NSUTF8StringEncoding];
        if (s && self.onText) self.onText(s);
    } else if (self.onBinary) {
        self.onBinary([_payloadBuf copy]);
    }
    [_payloadBuf setLength:0];
}

- (NSData *)_inflate:(NSData *)data {
    if (data.length == 0) return [NSData data];
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -_inflateWindowBits) != Z_OK) return nil;
    strm.next_in = (Bytef *)data.bytes;
    strm.avail_in = (uInt)data.length;
    NSMutableData *out = [NSMutableData data];
    uint8_t buf[16384];
    int ret;
    do {
        strm.next_out = buf;
        strm.avail_out = sizeof(buf);
        ret = inflate(&strm, Z_SYNC_FLUSH);
        if (ret == Z_NEED_DICT || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
            inflateEnd(&strm);
            return nil;
        }
        [out appendBytes:buf length:sizeof(buf) - strm.avail_out];
        if (ret == Z_STREAM_END) break;
    } while (strm.avail_in > 0);
    inflateEnd(&strm);
    if (out.length >= 4) {
        const uint8_t *tail = (const uint8_t *)out.bytes + out.length - 4;
        if (tail[0] == 0x00 && tail[1] == 0x00 && tail[2] == 0xFF && tail[3] == 0xFF) {
            [out setLength:out.length - 4];
        }
    }
    return out;
}

#pragma mark - 发送

- (void)sendText:(NSString *)text {
    if (_closed) return;
    if (!_handshakeDone) { [_sendQueue addObject:text]; return; }
    NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self _sendFrame:0x1 payload:payload];
}

- (void)_sendControl:(uint8_t)opcode payload:(NSData *)payload {
    [self _sendRawFrame:opcode payload:payload masked:NO];
}

- (void)_sendFrame:(uint8_t)opcode payload:(NSData *)payload {
    [self _sendRawFrame:opcode payload:payload masked:YES];
}

- (void)_sendRawFrame:(uint8_t)opcode payload:(NSData *)payload masked:(BOOL)masked {
    NSMutableData *frame = [NSMutableData data];
    uint8_t b0 = 0x80 | opcode;  // FIN=1
    [frame appendBytes:&b0 length:1];
    uint8_t b1 = 0;
    NSUInteger len = payload.length;
    if (masked) b1 |= 0x80;
    if (len < 126) {
        b1 |= (uint8_t)len;
        [frame appendBytes:&b1 length:1];
    } else if (len <= 0xFFFF) {
        b1 |= 126;
        [frame appendBytes:&b1 length:1];
        uint16_t l = (uint16_t)len;
        uint8_t lh[2] = {(uint8_t)(l >> 8), (uint8_t)(l & 0xFF)};
        [frame appendBytes:lh length:2];
    } else {
        b1 |= 127;
        [frame appendBytes:&b1 length:1];
        uint8_t lh[8];
        uint64_t l64 = len;
        for (int i = 7; i >= 0; i--) { lh[i] = (uint8_t)(l64 & 0xFF); l64 >>= 8; }
        [frame appendBytes:lh length:8];
    }
    if (masked) {
        unsigned char key[4];
        for (int i = 0; i < 4; i++) key[i] = (unsigned char)arc4random_uniform(256);
        [frame appendBytes:key length:4];
        NSMutableData *maskedPayload = [NSMutableData dataWithLength:len];
        const uint8_t *src = (const uint8_t *)payload.bytes;
        uint8_t *dst = (uint8_t *)maskedPayload.mutableBytes;
        for (NSUInteger i = 0; i < len; i++) dst[i] = src[i] ^ key[i & 3];
        [frame appendData:maskedPayload];
    } else {
        [frame appendData:payload];
    }
    [self _sendRawData:frame tag:[NSString stringWithFormat:@"frame op=%u", opcode]];
}

// nw_connection_send 异步发送（不阻塞主线程）
- (void)_sendRawData:(NSData *)data tag:(NSString *)tag {
    if (_closed || !_conn) { [self _log:@"send skipped (closed) %@", tag]; return; }
    dispatch_data_t dd = dispatch_data_create(data.bytes, data.length, dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    __weak WSClient *wSelf = self;
    nw_connection_send(_conn, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        WSClient *s = wSelf;
        if (!s) return;
        if (error) {
            [s _log:@"%@ send error", tag];
            [s _fail:@"send error"];
        } else {
            [s _log:@"%@ sent %luB", tag, (unsigned long)data.length];
        }
    });
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    if (_conn) { nw_connection_cancel(_conn); _conn = NULL; }
}

- (void)dealloc {
    if (!_closed) [self close];
}

- (void)_fail:(NSString *)err {
    if (_closed) return;
    NSString *e = [err copy];
    [self _log:@"FAIL: %@", e];
    [self close];
    if (self.onClose) self.onClose(e);
}

// 日志直写 tts_debug.log（不依赖 onLog/VC 链路，双通道）
- (void)_log:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *p = @"/var/mobile/Documents/tts_debug.log";
    NSString *entry = [NSString stringWithFormat:@"[ws] %@\n", line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [entry writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    if (self.onLog) self.onLog(line);
}

@end
