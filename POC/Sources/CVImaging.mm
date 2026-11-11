#import "CVImaging.h"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <algorithm>
#import <vector>

static const int kCanonicalSize = 512;

@implementation CVImaging

static cv::Mat matFromRGBA(NSData *data, NSInteger width, NSInteger height) {
    if (width <= 0 || height <= 0) { return cv::Mat(); }
    if (data.length < (NSUInteger)(width * height * 4)) { return cv::Mat(); }
    cv::Mat rgba((int)height, (int)width, CV_8UC4, (void *)data.bytes);
    cv::Mat rgb;
    cv::cvtColor(rgba, rgb, cv::COLOR_RGBA2RGB);
    return rgb.clone();
}

static NSData *dataFromRGB(const cv::Mat &rgb) {
    cv::Mat rgba;
    cv::cvtColor(rgb, rgba, cv::COLOR_RGB2RGBA);
    return [NSData dataWithBytes:rgba.data length:(NSUInteger)(rgba.total() * 4)];
}

static float percentile(std::vector<float> &values, double p) {
    if (values.empty()) { return 0.0f; }
    size_t index = (size_t)((values.size() - 1) * (p / 100.0));
    std::nth_element(values.begin(), values.begin() + index, values.end());
    return values[index];
}

/// 内容外接框（照抄 Android estimateContentBbox）
static bool estimateContentBbox(const cv::Mat &rgb, int &rx1, int &ry1, int &rx2, int &ry2) {
    const int w = rgb.cols;
    const int h = rgb.rows;
    if (std::min(h, w) < 80) { return false; }

    const double scale = 420.0 / (double)std::max(h, w);
    cv::Mat small;
    if (scale < 1.0) {
        int sw = std::max(1, (int)(w * scale));
        int sh = std::max(1, (int)(h * scale));
        cv::resize(rgb, small, cv::Size(sw, sh), 0, 0, cv::INTER_AREA);
    } else {
        small = rgb;
    }
    const int sh = small.rows;
    const int sw = small.cols;

    cv::Mat work;
    small.convertTo(work, CV_32FC3);
    const double sigma = std::max(6.0, std::min(sh, sw) * 0.042);
    cv::Mat background;
    cv::GaussianBlur(work, background, cv::Size(0, 0), sigma);

    std::vector<cv::Mat> chWork, chBg;
    cv::split(work, chWork);
    cv::split(background, chBg);
    std::vector<float> diff((size_t)(sh * sw), 0.0f);
    for (int c = 0; c < 3; ++c) {
        const float *a = chWork[c].ptr<float>(0);
        const float *b = chBg[c].ptr<float>(0);
        for (int i = 0; i < sh * sw; ++i) {
            float d = a[i] - b[i];
            diff[i] += d * d;
        }
    }
    for (int i = 0; i < sh * sw; ++i) { diff[i] = std::sqrt(diff[i]); }

    const int border = std::max(3, (int)(std::min(sh, sw) * 0.038));
    std::vector<float> borderValues;
    borderValues.reserve((size_t)(border * sw * 2 + border * sh * 2));
    for (int y = 0; y < border; ++y)
        for (int x = 0; x < sw; ++x) borderValues.push_back(diff[y * sw + x]);
    for (int y = sh - border; y < sh; ++y)
        for (int x = 0; x < sw; ++x) borderValues.push_back(diff[y * sw + x]);
    for (int y = 0; y < sh; ++y)
        for (int x = 0; x < border; ++x) borderValues.push_back(diff[y * sw + x]);
    for (int y = 0; y < sh; ++y)
        for (int x = sw - border; x < sw; ++x) borderValues.push_back(diff[y * sw + x]);

    const float noise = percentile(borderValues, 95.0);
    const float threshold = std::max(5.0f, noise * 2.1f + 2.5f);

    cv::Mat mask(sh, sw, CV_8UC1);
    for (int i = 0; i < sh * sw; ++i) {
        mask.data[i] = diff[(size_t)i] > threshold ? 255 : 0;
    }

    cv::Mat k2 = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(2, 2));
    cv::Mat k11 = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(11, 11));
    cv::Mat k19 = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(19, 19));
    cv::morphologyEx(mask, mask, cv::MORPH_OPEN, k2);
    cv::dilate(mask, mask, k11, cv::Point(-1, -1), 1);
    cv::morphologyEx(mask, mask, cv::MORPH_CLOSE, k19);

    int nonZero = cv::countNonZero(mask);
    double fraction = (double)nonZero / (double)(sh * sw);
    if (fraction < 0.012 || fraction > 0.90) { return false; }

    cv::Mat labels, stats, centroids;
    int count = cv::connectedComponentsWithStats(mask, labels, stats, centroids, 8, CV_32S);
    if (count <= 1) { return false; }

    const int minArea = std::max(30, (int)(sh * sw * 0.0008));
    int x1 = INT_MAX, y1 = INT_MAX, x2 = INT_MIN, y2 = INT_MIN;
    bool found = false;
    for (int index = 1; index < count; ++index) {
        int area = stats.at<int>(index, cv::CC_STAT_AREA);
        if (area >= minArea) {
            found = true;
            x1 = std::min(x1, stats.at<int>(index, cv::CC_STAT_LEFT));
            y1 = std::min(y1, stats.at<int>(index, cv::CC_STAT_TOP));
            x2 = std::max(x2, stats.at<int>(index, cv::CC_STAT_LEFT) + stats.at<int>(index, cv::CC_STAT_WIDTH));
            y2 = std::max(y2, stats.at<int>(index, cv::CC_STAT_TOP) + stats.at<int>(index, cv::CC_STAT_HEIGHT));
        }
    }
    if (!found) { return false; }

    double spanX = (double)(x2 - x1) / sw;
    double spanY = (double)(y2 - y1) / sh;
    if (spanX < 0.18 || spanY < 0.18) { return false; }
    if (spanX > 0.975 && spanY > 0.975) { return false; }

    const int marginX = std::max(2, (int)((x2 - x1) * 0.025));
    const int marginY = std::max(2, (int)((y2 - y1) * 0.025));
    rx1 = std::max(0, (int)((x1 - marginX) * (double)w / sw));
    ry1 = std::max(0, (int)((y1 - marginY) * (double)h / sh));
    rx2 = std::min(w, (int)((x2 + marginX) * (double)w / sw));
    ry2 = std::min(h, (int)((y2 + marginY) * (double)h / sh));
    if (rx2 - rx1 < w * 0.15 || ry2 - ry1 < h * 0.15) { return false; }
    if ((long)(rx2 - rx1) * (long)(ry2 - ry1) > (long)w * h * 0.965) { return false; }
    return true;
}

+ (NSData *)canonicalRGBA:(NSData *)rgba
                    width:(NSInteger)width
                   height:(NSInteger)height
                 autoCrop:(BOOL)autoCrop
                 outWidth:(NSInteger *)outWidth
                outHeight:(NSInteger *)outHeight {
    cv::Mat rgb = matFromRGBA(rgba, width, height);
    if (rgb.empty()) { return nil; }

    if (autoCrop) {
        int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
        if (estimateContentBbox(rgb, x1, y1, x2, y2)) {
            rgb = rgb(cv::Rect(x1, y1, x2 - x1, y2 - y1)).clone();
        }
    }

    const int cw = rgb.cols;
    const int ch = rgb.rows;
    const int side = std::max(std::max(ch, cw), 1);
    const int pad = (int)lround(side * 0.055);
    const int canvasSide = side + pad * 2;

    cv::Mat canvas(canvasSide, canvasSide, CV_8UC3, cv::Scalar(247, 247, 247));
    const int ox = (canvasSide - cw) / 2;
    const int oy = (canvasSide - ch) / 2;
    rgb.copyTo(canvas(cv::Rect(ox, oy, cw, ch)));

    cv::Mat resized;
    cv::resize(canvas, resized, cv::Size(kCanonicalSize, kCanonicalSize), 0, 0, cv::INTER_LANCZOS4);

    if (outWidth) { *outWidth = resized.cols; }
    if (outHeight) { *outHeight = resized.rows; }
    return dataFromRGB(resized);
}

+ (NSData *)structureMapFromRGBA:(NSData *)rgba
                           width:(NSInteger)width
                          height:(NSInteger)height
                            size:(NSInteger)size {
    cv::Mat rgb = matFromRGBA(rgba, width, height);
    if (rgb.empty()) { return nil; }

    cv::Mat resized;
    cv::resize(rgb, resized, cv::Size((int)size, (int)size), 0, 0, cv::INTER_LANCZOS4);

    cv::Mat base;
    resized.convertTo(base, CV_32FC3, 1.0 / 255.0);
    cv::Mat blurred;
    cv::GaussianBlur(base, blurred, cv::Size(3, 3), 0.0);

    std::vector<cv::Mat> channels;
    cv::split(blurred, channels);
    cv::Mat magnitude;
    for (int c = 0; c < 3; ++c) {
        cv::Mat gx, gy, mag;
        cv::Sobel(channels[c], gx, CV_32F, 1, 0, 3);
        cv::Sobel(channels[c], gy, CV_32F, 0, 1, 3);
        cv::magnitude(gx, gy, mag);
        if (magnitude.empty()) {
            magnitude = mag.clone();
        } else {
            cv::max(magnitude, mag, magnitude);
        }
    }

    cv::Mat base8;
    blurred.convertTo(base8, CV_8UC3, 255.0);
    cv::Mat gray8, grayF;
    cv::cvtColor(base8, gray8, cv::COLOR_RGB2GRAY);
    gray8.convertTo(grayF, CV_32F, 1.0 / 255.0);
    cv::Mat gxg, gyg, magg;
    cv::Sobel(grayF, gxg, CV_32F, 1, 0, 3);
    cv::Sobel(grayF, gyg, CV_32F, 0, 1, 3);
    cv::magnitude(gxg, gyg, magg);
    cv::max(magnitude, magg, magnitude);

    cv::Mat local;
    cv::GaussianBlur(magnitude, local, cv::Size(0, 0), 13.0);

    std::vector<float> data((size_t)(size * size));
    std::vector<float> localData((size_t)(size * size));
    std::memcpy(data.data(), magnitude.ptr<float>(0), data.size() * sizeof(float));
    std::memcpy(localData.data(), local.ptr<float>(0), localData.size() * sizeof(float));
    for (size_t i = 0; i < data.size(); ++i) {
        data[i] = std::max(data[i] - 0.28f * localData[i], 0.0f);
    }

    std::vector<float> sorted = data;
    const float high = percentile(sorted, 99.3);

    cv::Mat shaped((int)size, (int)size, CV_32FC1);
    float *out = shaped.ptr<float>(0);
    if (high < 1e-6f) {
        std::fill(out, out + data.size(), 0.0f);
    } else {
        for (size_t i = 0; i < data.size(); ++i) {
            double value = std::min(std::max((double)data[i] / (double)high, 0.0), 1.0);
            out[i] = (float)std::pow(value, 0.72);
        }
    }

    cv::Mat smooth;
    cv::GaussianBlur(shaped, smooth, cv::Size(0, 0), 1.15);
    cv::Mat result;
    smooth.convertTo(result, CV_8UC1, 255.0);
    return [NSData dataWithBytes:result.data length:(NSUInteger)(size * size)];
}

+ (NSData *)claheGrayFromRGBA:(NSData *)rgba
                        width:(NSInteger)width
                       height:(NSInteger)height {
    cv::Mat rgb = matFromRGBA(rgba, width, height);
    if (rgb.empty()) { return nil; }
    cv::Mat gray;
    cv::cvtColor(rgb, gray, cv::COLOR_RGB2GRAY);
    cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(2.0, cv::Size(8, 8));
    cv::Mat equalized;
    clahe->apply(gray, equalized);
    return [NSData dataWithBytes:equalized.data length:(NSUInteger)(width * height)];
}

@end
