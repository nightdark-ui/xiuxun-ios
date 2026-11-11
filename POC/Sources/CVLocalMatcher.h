#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SIFT + 单应验证的局部匹配（Objective-C++ 封装，Swift 通过桥接头调用）。
///
/// 对应 PC `matching.py` 的 local_match：SIFT 关键点 → 比值检验 → RANSAC 单应。
@interface CVLocalMatcher : NSObject

/// 两张图的局部匹配度
/// - Parameters:
///   - queryRGBA: 查询图 RGBA8 原始字节
///   - designRGBA: 图库图 RGBA8 原始字节
/// - Returns: 0…1；无法匹配返回 0
+ (double)matchQuery:(NSData *)queryRGBA
              qWidth:(NSInteger)qWidth
             qHeight:(NSInteger)qHeight
          designRGBA:(NSData *)designRGBA
             dWidth:(NSInteger)dWidth
            dHeight:(NSInteger)dHeight;

/// 自检：OpenCV 是否成功链接
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
