#import "CVLocalMatcher.h"
// 不能 import <opencv2/opencv.hpp>：会把 stitching 头带进来，与 Objective-C 的 NO 宏冲突。
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>

struct SiftStorage {
    cv::Mat gray;
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
};

@interface CVSiftFeatures ()
@property (nonatomic, assign) void *storage;
@end

@implementation CVSiftFeatures

- (instancetype)init {
    self = [super init];
    if (self) {
        _storage = new SiftStorage();
    }
    return self;
}

- (void)dealloc {
    delete (SiftStorage *)_storage;
    _storage = nullptr;
}

@end

@implementation CVLocalMatcher

+ (BOOL)isAvailable {
    return YES;
}

static SiftStorage *storageOf(CVSiftFeatures *features) {
    return (SiftStorage *)features.storage;
}

static cv::Mat grayFromRGBA(NSData *data, NSInteger width, NSInteger height) {
    if (width <= 0 || height <= 0) { return cv::Mat(); }
    if (data.length < (NSUInteger)(width * height * 4)) { return cv::Mat(); }
    cv::Mat rgba((int)height, (int)width, CV_8UC4, (void *)data.bytes);
    cv::Mat gray;
    cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY);
    const int maxSide = 800;
    int longest = std::max(gray.cols, gray.rows);
    if (longest > maxSide) {
        double scale = (double)maxSide / (double)longest;
        cv::resize(gray, gray, cv::Size(), scale, scale, cv::INTER_AREA);
    }
    cv::equalizeHist(gray, gray);
    return gray;
}

+ (CVSiftFeatures *)extractFeatures:(NSData *)rgba width:(NSInteger)width height:(NSInteger)height {
    CVSiftFeatures *features = [[CVSiftFeatures alloc] init];
    SiftStorage *storage = storageOf(features);
    cv::Mat gray = grayFromRGBA(rgba, width, height);
    if (gray.empty()) { return features; }
    storage->gray = gray;
    cv::Ptr<cv::SIFT> sift = cv::SIFT::create(0, 3, 0.04, 10.0, 1.6);
    sift->detectAndCompute(gray, cv::noArray(), storage->keypoints, storage->descriptors);
    return features;
}

static double scoreFromMatches(
    const std::vector<cv::KeyPoint> &queryKp,
    const cv::Mat &queryDesc,
    const cv::Mat &designDesc,
    const std::vector<cv::KeyPoint> &designKp
) {
    if (queryDesc.empty() || designDesc.empty()) { return 0.0; }
    if (queryKp.size() < 4 || designKp.size() < 4) { return 0.0; }

    cv::BFMatcher matcher(cv::NORM_L2);
    std::vector<std::vector<cv::DMatch>> knn;
    matcher.knnMatch(queryDesc, designDesc, knn, 2);

    std::vector<cv::Point2f> ptsQuery, ptsDesign;
    for (const auto &pair : knn) {
        if (pair.size() < 2) { continue; }
        if (pair[0].distance < 0.75f * pair[1].distance) {
            ptsQuery.push_back(queryKp[pair[0].queryIdx].pt);
            ptsDesign.push_back(designKp[pair[0].trainIdx].pt);
        }
    }
    if (ptsQuery.size() < 6) { return 0.0; }

    cv::Mat mask;
    cv::Mat homography = cv::findHomography(ptsQuery, ptsDesign, cv::RANSAC, 5.0, mask);
    if (homography.empty() || mask.empty()) { return 0.0; }

    int inliers = cv::countNonZero(mask);
    double ratio = (double)inliers / (double)ptsQuery.size();
    double coverage = (double)inliers / (double)std::max<size_t>(queryKp.size(), 1);
    double score = 0.65 * ratio + 0.35 * std::min(1.0, coverage * 2.0);
    return std::max(0.0, std::min(1.0, score));
}

+ (double)matchFeatures:(CVSiftFeatures *)query against:(CVSiftFeatures *)design {
    if (query == nil || design == nil) { return 0.0; }
    SiftStorage *q = storageOf(query);
    SiftStorage *d = storageOf(design);
    return scoreFromMatches(q->keypoints, q->descriptors, d->descriptors, d->keypoints);
}

+ (double)matchFeatures:(CVSiftFeatures *)query
        designKeypoints:(NSData *)keypoints
      designDescriptors:(NSData *)descriptors {
    if (query == nil || keypoints.length < 20 || descriptors.length < 128 * 4) { return 0.0; }
    SiftStorage *q = storageOf(query);
    if (q->descriptors.empty() || q->keypoints.size() < 4) { return 0.0; }

    const size_t count = descriptors.length / (128 * sizeof(float));
    if (count < 4 || keypoints.length < count * 5 * sizeof(float)) { return 0.0; }

    cv::Mat descMat((int)count, 128, CV_32F, (void *)descriptors.bytes);
    const float *kpData = (const float *)keypoints.bytes;
    std::vector<cv::KeyPoint> designKp;
    designKp.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const float *row = kpData + i * 5;
        designKp.emplace_back(cv::Point2f(row[0], row[1]), row[2], row[3], row[4]);
    }
    return scoreFromMatches(q->keypoints, q->descriptors, descMat, designKp);
}

+ (double)matchQuery:(NSData *)queryRGBA
              qWidth:(NSInteger)qWidth
             qHeight:(NSInteger)qHeight
          designRGBA:(NSData *)designRGBA
             dWidth:(NSInteger)dWidth
            dHeight:(NSInteger)dHeight {
    @autoreleasepool {
        CVSiftFeatures *q = [self extractFeatures:queryRGBA width:qWidth height:qHeight];
        CVSiftFeatures *d = [self extractFeatures:designRGBA width:dWidth height:dHeight];
        return [self matchFeatures:q against:d];
    }
}

@end
