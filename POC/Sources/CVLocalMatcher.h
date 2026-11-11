#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 预先提取好的 SIFT 特征
@interface CVSiftFeatures : NSObject
@end

@interface CVLocalMatcher : NSObject

+ (nullable CVSiftFeatures *)extractFeatures:(NSData *)rgba
                                      width:(NSInteger)width
                                     height:(NSInteger)height;

+ (double)matchFeatures:(CVSiftFeatures *)query
                against:(CVSiftFeatures *)design;

/// 用 heavy.bin 里缓存的 SIFT 特征匹配（不解码、不检测设计图）
+ (double)matchFeatures:(CVSiftFeatures *)query
        designKeypoints:(NSData *)keypoints
      designDescriptors:(NSData *)descriptors;

+ (double)matchQuery:(NSData *)queryRGBA
              qWidth:(NSInteger)qWidth
             qHeight:(NSInteger)qHeight
          designRGBA:(NSData *)designRGBA
             dWidth:(NSInteger)dWidth
            dHeight:(NSInteger)dHeight;

+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
