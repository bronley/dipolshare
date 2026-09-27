#import "LocalSendFormatting.h"

NSString *LocalSendFormattedFileSize(unsigned long long byteCount) {
    if (byteCount < 1024ULL) {
        return [NSString stringWithFormat:@"%llu bytes", byteCount];
    }
    if (byteCount < 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f KB", (double)byteCount / 1024.0];
    }
    if (byteCount < 1024ULL * 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f MB", (double)byteCount / (1024.0 * 1024.0)];
    }
    return [NSString stringWithFormat:@"%.1f GB", (double)byteCount / (1024.0 * 1024.0 * 1024.0)];
}
