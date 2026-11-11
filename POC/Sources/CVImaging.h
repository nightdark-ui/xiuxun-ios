#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// PC/安卓 `imaging.py` 的 OpenCV 直译：统一画布 + 结构图 + 灰度 CLAHE。
/// 数值与 PC/安卓一致（同一套 cv2 调用），避免手写近似带来的偏差。
@interface CVImaging : NSObject

/// make_canonical：自动裁切 → 5.5% 留白 → 512×512（返回 RGBA8）
+ (nullable NSData *)canonicalRGBA:(NSData *)rgba
                             width:(NSInteger)width
                            height:(NSInteger)height
                          autoCrop:(BOOL)autoCrop
                          outWidth:(NSInteger *)outWidth
                         outHeight:(NSInteger *)outHeight;

/// structure_map：三通道 + 灰度 Sobel 取最大 → 去低频 → 99.3 分位 → γ0.72 → 模糊
+ (nullable NSData *)structureMapFromRGBA:(NSData *)rgba
                                    width:(NSInteger)width
                                   height:(NSInteger)height
                                     size:(NSInteger)size;

/// _prepare 的前两步：RGB → 灰度 → CLAHE(2.0, 8×8)，返回灰度字节
+ (nullable NSData *)claheGrayFromRGBA:(NSData *)rgba
                                 width:(NSInteger)width
                                height:(NSInteger)height;

@end

NS_ASSUME_NONNULL_END
