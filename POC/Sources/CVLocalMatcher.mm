#import "CVLocalMatcher.h"
// 不能 import <opencv2/opencv.hpp>：它会把 stitching 头带进来，
// 其中 enum { NO, ... } 与 Objective-C 的 NO 宏冲突。
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>

@implementation CVLocalMatcher

+ (BOOL)isAvailable {
    return YES;
}

static cv::Mat matFromRGBA(NSData *data, NSInteger width, NSInteger height) {
    if (data.length < (NSUInteger)(width * height * 4) || width <= 0 || height <= 0) {
        return cv::Mat();
    }
    // RGBA -> BGRA（OpenCV 用 BGRA 顺序）
    cv::Mat rgba((int)height, (int)width, CV_8UC4, (void *)data.bytes);
    cv::Mat bgra;
    cv::cvtColor(rgba, bgra, cv::COLOR_RGBA2BGRA);
    cv::Mat gray;
    cv::cvtColor(bgra, gray, cv::COLOR_BGRA2GRAY);
    // 控制计算量：长边缩到 800
    const int maxSide = 800;
    int longest = std::max(gray.cols, gray.rows);
    if (longest > maxSide) {
        double scale = (double)maxSide / (double)longest;
        cv::resize(gray, gray, cv::Size(), scale, scale, cv::INTER_AREA);
    }
    cv::equalizeHist(gray, gray);
    return gray;
}

+ (double)matchQuery:(NSData *)queryRGBA
              qWidth:(NSInteger)qWidth
             qHeight:(NSInteger)qHeight
          designRGBA:(NSData *)designRGBA
             dWidth:(NSInteger)dWidth
            dHeight:(NSInteger)dHeight {
    @autoreleasepool {
        cv::Mat q = matFromRGBA(queryRGBA, qWidth, qHeight);
        cv::Mat d = matFromRGBA(designRGBA, dWidth, dHeight);
        if (q.empty() || d.empty()) {
            return 0.0;
        }

        cv::Ptr<cv::SIFT> sift = cv::SIFT::create(0, 3, 0.04, 10.0, 1.6);
        std::vector<cv::KeyPoint> kpQ, kpD;
        cv::Mat descQ, descD;
        sift->detectAndCompute(q, cv::noArray(), kpQ, descQ);
        sift->detectAndCompute(d, cv::noArray(), kpD, descD);
        if (descQ.empty() || descD.empty() || kpQ.size() < 4 || kpD.size() < 4) {
            return 0.0;
        }

        cv::BFMatcher matcher(cv::NORM_L2);
        std::vector<std::vector<cv::DMatch>> knn;
        matcher.knnMatch(descQ, descD, knn, 2);

        std::vector<cv::Point2f> ptsQ, ptsD;
        for (const auto &pair : knn) {
            if (pair.size() < 2) { continue; }
            if (pair[0].distance < 0.75f * pair[1].distance) {
                ptsQ.push_back(kpQ[pair[0].queryIdx].pt);
                ptsD.push_back(kpD[pair[0].trainIdx].pt);
            }
        }
        if (ptsQ.size() < 6) {
            return 0.0;
        }

        cv::Mat mask;
        cv::Mat H = cv::findHomography(ptsQ, ptsD, cv::RANSAC, 5.0, mask);
        if (H.empty() || mask.empty()) {
            return 0.0;
        }
        int inliers = cv::countNonZero(mask);
        double ratio = (double)inliers / (double)ptsQ.size();
        double coverage = (double)inliers / (double)std::max<size_t>(kpQ.size(), 1);
        // 内点比例 + 覆盖率（对照 PC 的打分思路）
        double score = 0.65 * ratio + 0.35 * std::min(1.0, coverage * 2.0);
        return std::max(0.0, std::min(1.0, score));
    }
}

@end
