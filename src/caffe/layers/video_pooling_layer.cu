#include <cfloat>

#include "caffe/util/math_functions.hpp"
#include "caffe/layers/video_pooling_layer.hpp"

using std::max;
using std::min;

namespace caffe {

template <typename Dtype>
__global__ void VideoPoolForward(const int nthreads, const Dtype* bottom_data,
    const Dtype spatial_scale, const int pooled_parts, const int frames,
    const int channels, const int height, const int width, const int pooled_height,
    const int pooled_width, const Dtype pad_ratio, const Dtype* bottom_rois,
    Dtype* top_data, int* argmax_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    // (b, pp, f, c, ph, pw) is an element in the pooled output

    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int f = (index / pooled_width / pooled_height / channels) % frames;
    int pp = (index / pooled_width / pooled_height / channels / frames) % pooled_parts;
    int b = index / pooled_width / pooled_height / channels / frames / pooled_parts;

    bottom_rois += (b * pooled_parts * 4 + pp * 4);

    // padding
    Dtype pad_w, pad_h;
    pad_w = (bottom_rois[2]-bottom_rois[0]+1)*pad_ratio;
    pad_h = (bottom_rois[3]-bottom_rois[1]+1)*pad_ratio;
    int roi_start_w = round((bottom_rois[0]-pad_w) * spatial_scale);
    int roi_start_h = round((bottom_rois[1]-pad_h) * spatial_scale);
    int roi_end_w = round((bottom_rois[2]+pad_w) * spatial_scale);
    int roi_end_h = round((bottom_rois[3]+pad_h) * spatial_scale);
    // clipping
    /*roi_start_w = max(roi_start_w,0); roi_start_h = max(roi_start_h,0);
    int img_width = round(width / spatial_scale);
    int img_height = round(height / spatial_scale);
    roi_end_w = min(img_width-1,roi_end_w);
    roi_end_h = min(img_height-1,roi_end_h);*/

    // Force malformed ROIs to be 1x1
    int roi_width = max(roi_end_w - roi_start_w + 1, 1);
    int roi_height = max(roi_end_h - roi_start_h + 1, 1);
    Dtype bin_size_h = static_cast<Dtype>(roi_height)
                       / static_cast<Dtype>(pooled_height);
    Dtype bin_size_w = static_cast<Dtype>(roi_width)
                       / static_cast<Dtype>(pooled_width);

    int hstart = static_cast<int>(floor(static_cast<Dtype>(ph)
                                        * bin_size_h));
    int wstart = static_cast<int>(floor(static_cast<Dtype>(pw)
                                        * bin_size_w));
    int hend = static_cast<int>(ceil(static_cast<Dtype>(ph + 1)
                                     * bin_size_h));
    int wend = static_cast<int>(ceil(static_cast<Dtype>(pw + 1)
                                     * bin_size_w));

    // Add roi offsets and clip to input boundaries
    hstart = min(max(hstart + roi_start_h, 0), height);
    hend = min(max(hend + roi_start_h, 0), height);
    wstart = min(max(wstart + roi_start_w, 0), width);
    wend = min(max(wend + roi_start_w, 0), width);
    bool is_empty = (hend <= hstart) || (wend <= wstart);

    // Define an empty pooling region to be zero
    Dtype maxval = is_empty ? 0 : -FLT_MAX;
    // If nothing is pooled, argmax = -1 causes nothing to be backprop'd
    int maxidx = -1;
    bottom_data += (b * frames * channels + f * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        int bottom_index = h * width + w;
        if (bottom_data[bottom_index] > maxval) {
          maxval = bottom_data[bottom_index];
          maxidx = bottom_index;
        }
      }
    }
    top_data[index] = maxval;
    argmax_data[index] = maxidx;
  }
}

template <typename Dtype>
void VideoPoolingLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) {
  const Dtype* bottom_data = bottom[0]->gpu_data();
  const Dtype* bottom_rois = bottom[1]->gpu_data();
  Dtype* top_data = top[0]->mutable_gpu_data();
  int* argmax_data = max_idx_.mutable_gpu_data();
  int count = top[0]->count();
  // NOLINT_NEXT_LINE(whitespace/operators)
  VideoPoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
      count, bottom_data, spatial_scale_, pooled_parts_, frames_, channels_,
      height_, width_, pooled_height_, pooled_width_, pad_ratio_, bottom_rois,
      top_data, argmax_data);
  CUDA_POST_KERNEL_CHECK;
}

template <typename Dtype>
__global__ void VideoPoolBackward(const int nthreads, const Dtype* top_diff,
    const int* argmax_data, const Dtype spatial_scale, const int pooled_parts,
    const int frames, const int channels, const int height, const int width,
    const int pooled_height, const int pooled_width, const Dtype pad_ratio, 
    Dtype* bottom_diff, const Dtype* bottom_rois) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    // (b, f, c, h, w) coords in bottom data
    int w = index % width;
    int h = (index / width) % height;
    int c = (index / width / height) % channels;
    int f = (index / width / height / channels) % frames;
    int b = index / width / height / channels / frames;

    Dtype gradient = 0;
    // Accumulate gradient over all ROIs that pooled this element
    for (int pp = 0; pp < pooled_parts; pp++) {
      const Dtype* offset_bottom_rois = bottom_rois
	      				+ (b * pooled_parts + pp) * 4;
      
      // padding
      Dtype pad_w, pad_h;
      pad_w = (offset_bottom_rois[2]-offset_bottom_rois[0]+1)*pad_ratio;
      pad_h = (offset_bottom_rois[3]-offset_bottom_rois[1]+1)*pad_ratio;
      int roi_start_w = round((offset_bottom_rois[0]-pad_w) * spatial_scale);
      int roi_start_h = round((offset_bottom_rois[1]-pad_h) * spatial_scale);
      int roi_end_w = round((offset_bottom_rois[2]+pad_w) * spatial_scale);
      int roi_end_h = round((offset_bottom_rois[3]+pad_h) * spatial_scale);
      // clipping
      roi_start_w = max(roi_start_w,0); roi_start_h = max(roi_start_h,0);
      int img_width = round(width / spatial_scale);
      int img_height = round(height / spatial_scale);
      roi_end_w = min(img_width-1,roi_end_w);
      roi_end_h = min(img_height-1,roi_end_h);


      // Skip if ROI doesn't include (h, w)
      const bool in_roi = (w >= roi_start_w && w <= roi_end_w &&
                           h >= roi_start_h && h <= roi_end_h);
      if (!in_roi) {
        continue;
      }

      int offset = (b * pooled_parts * frames * channels
		    + pp * frames * channels
		    + f * channels + c) * pooled_height * pooled_width;
      const Dtype* offset_top_diff = top_diff + offset;
      const int* offset_argmax_data = argmax_data + offset;

      // Compute feasible set of pooled units that could have pooled
      // this bottom unit

      // Force malformed ROIs to be 1x1
      int roi_width = max(roi_end_w - roi_start_w + 1, 1);
      int roi_height = max(roi_end_h - roi_start_h + 1, 1);

      Dtype bin_size_h = static_cast<Dtype>(roi_height)
                         / static_cast<Dtype>(pooled_height);
      Dtype bin_size_w = static_cast<Dtype>(roi_width)
                         / static_cast<Dtype>(pooled_width);

      int phstart = floor(static_cast<Dtype>(h - roi_start_h) / bin_size_h);
      int phend = ceil(static_cast<Dtype>(h - roi_start_h + 1) / bin_size_h);
      int pwstart = floor(static_cast<Dtype>(w - roi_start_w) / bin_size_w);
      int pwend = ceil(static_cast<Dtype>(w - roi_start_w + 1) / bin_size_w);

      phstart = min(max(phstart, 0), pooled_height);
      phend = min(max(phend, 0), pooled_height);
      pwstart = min(max(pwstart, 0), pooled_width);
      pwend = min(max(pwend, 0), pooled_width);

      for (int ph = phstart; ph < phend; ++ph) {
        for (int pw = pwstart; pw < pwend; ++pw) {
          if (offset_argmax_data[ph * pooled_width + pw] == (h * width + w)) {
            gradient += offset_top_diff[ph * pooled_width + pw];
          }
        }
      }
    }
    bottom_diff[index] = gradient;
  }
}

template <typename Dtype>
void VideoPoolingLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
      const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {
  if (!propagate_down[0]) {
    return;
  }
  const Dtype* bottom_rois = bottom[1]->gpu_data();
  const Dtype* top_diff = top[0]->gpu_diff();
  Dtype* bottom_diff = bottom[0]->mutable_gpu_diff();
  const int count = bottom[0]->count();
  caffe_gpu_set(count, Dtype(0.), bottom_diff);
  const int* argmax_data = max_idx_.gpu_data();
  // NOLINT_NEXT_LINE(whitespace/operators)
  VideoPoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
      count, top_diff, argmax_data, spatial_scale_, pooled_parts_, frames_, channels_,
      height_, width_, pooled_height_, pooled_width_, pad_ratio_, bottom_diff, bottom_rois);
  CUDA_POST_KERNEL_CHECK;
}

INSTANTIATE_LAYER_GPU_FUNCS(VideoPoolingLayer);

}  // namespace caffe
