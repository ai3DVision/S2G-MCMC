#include <algorithm>
#include <cfloat>
#include <vector>

#include "caffe/layer.hpp"
#include "caffe/util/math_functions.hpp"
#include "caffe/vision_layers.hpp"

namespace caffe {

template <typename Dtype>
__global__ void SoftmaxLossForwardGPU(const int nthreads,
          const Dtype* prob_data, const Dtype* label, Dtype* loss,
          const int num, const int dim, const int spatial_dim,
          const bool has_ignore_label_, const int ignore_label_,
          Dtype* counts) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    const int n = index / spatial_dim;
    const int s = index % spatial_dim;
    const int label_value = static_cast<int>(label[n * spatial_dim + s]);
    if (has_ignore_label_ && label_value == ignore_label_) {
      loss[index] = 0;
      counts[index] = 0;
    } else {
      loss[index] = -log(max(prob_data[n * dim + label_value * spatial_dim + s],
                      Dtype(FLT_MIN)));
      counts[index] = 1;
    }
  }
}

template <typename Dtype>
void SoftmaxWithLossBDKLayer<Dtype>::Forward_gpu(
    const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) {
  this->softmax_layer_->Forward(this->softmax_bottom_vec_, this->softmax_top_vec_);
  const Dtype* prob_data = this->prob_.gpu_data();
  const Dtype* label = bottom[1]->gpu_data();
  const int dim = this->prob_.count() / this->outer_num_;
  const int nthreads = this->outer_num_ * this->inner_num_;
  // Since this memory is not used for anything until it is overwritten
  // on the backward pass, we use it here to avoid having to allocate new GPU
  // memory to accumulate intermediate results in the kernel.
  Dtype* loss_data = bottom[0]->mutable_gpu_diff();
  // Similarly, this memory is never used elsewhere, and thus we can use it
  // to avoid having to allocate additional GPU memory.
  Dtype* counts = this->prob_.mutable_gpu_diff();
  // NOLINT_NEXT_LINE(whitespace/operators)
  SoftmaxLossForwardGPU<Dtype><<<CAFFE_GET_BLOCKS(nthreads),
      CAFFE_CUDA_NUM_THREADS>>>(nthreads, prob_data, label, loss_data,
      this->outer_num_, dim, this->inner_num_, this->has_ignore_label_, this->ignore_label_, counts);
  Dtype loss;
  caffe_gpu_asum(nthreads, loss_data, &loss);
  if (this->normalize_) {
    Dtype count;
    caffe_gpu_asum(nthreads, counts, &count);
    loss /= count;
  } else {
    loss /= this->outer_num_;
  }
  top[0]->mutable_cpu_data()[0] = loss;
  if (top.size() == 2) {
    top[1]->ShareData(this->prob_);
  }
  
  this->softmax_layer_1_->Forward(this->softmax_bottom_vec_1_, this->softmax_top_vec_1_);
}

template <typename Dtype>
__global__ void SoftmaxLossBackwardGPU(const int nthreads, const Dtype* top,
          const Dtype* label, Dtype* bottom_diff, const int num, const int dim,
          const int spatial_dim, const bool has_ignore_label_,
          const int ignore_label_, Dtype* counts) {
  const int channels = dim / spatial_dim;

  CUDA_KERNEL_LOOP(index, nthreads) {
    const int n = index / spatial_dim;
    const int s = index % spatial_dim;
    const int label_value = static_cast<int>(label[n * spatial_dim + s]);

    if (has_ignore_label_ && label_value == ignore_label_) {
      for (int c = 0; c < channels; ++c) {
        bottom_diff[n * dim + c * spatial_dim + s] = 0;
      }
      counts[index] = 0;
    } else {
      bottom_diff[n * dim + label_value * spatial_dim + s] -= 1;
      counts[index] = 1;
    }
  }
}

template <typename Dtype>
void SoftmaxWithLossBDKLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {
  if (propagate_down[1]) {
    LOG(FATAL) << this->type()
               << " Layer cannot backpropagate to label inputs.";
  }
  if (propagate_down[0]) {
    const int nthreads = this->outer_num_ * this->inner_num_;
    Dtype* counts = this->prob_.mutable_gpu_diff();
    
    Dtype* bottom_diff = bottom[0]->mutable_gpu_diff();
    Dtype* bottom_diff1 = bottom[2]->mutable_gpu_diff();
    const Dtype* prob_data = this->prob_.gpu_data();
    const Dtype* top_data = top[0]->gpu_data();
    caffe_gpu_memcpy(this->prob_.count() * sizeof(Dtype), prob_data, bottom_diff);
    caffe_gpu_memcpy(this->prob_.count() * sizeof(Dtype), prob_data, bottom_diff1);
    if(this->layer_param_.loss_param().down_sgld() == 0){
      caffe_gpu_scal(this->prob_.count(), Dtype(0), bottom_diff);
    }else{
    const Dtype* label = bottom[1]->gpu_data();
    const int dim = this->prob_.count() / this->outer_num_;
    //const int nthreads = this->outer_num_ * this->inner_num_;
    // Since this memory is never used for anything else,
    // we use to to avoid allocating new GPU memory.
    //Dtype* counts = this->prob_.mutable_gpu_diff();
    // NOLINT_NEXT_LINE(whitespace/operators)
    SoftmaxLossBackwardGPU<Dtype><<<CAFFE_GET_BLOCKS(nthreads),
        CAFFE_CUDA_NUM_THREADS>>>(nthreads, top_data, label, bottom_diff,
        this->outer_num_, dim, this->inner_num_, this->has_ignore_label_, this->ignore_label_, counts);}
    const Dtype loss_weight = top[0]->cpu_diff()[0];
    caffe_gpu_axpby(this->prob_1_.count(), Dtype(1), this->prob_1_.gpu_data(), Dtype(-1), bottom_diff1);
    if (this->normalize_) {
      Dtype count;
      caffe_gpu_asum(nthreads, counts, &count);
      if(this->layer_param_.loss_param().down_sgld() == 1){//LOG(INFO) << "loss_weight = " << loss_weight << ", count = " << count;
      caffe_gpu_scal(this->prob_.count(), loss_weight / count, bottom_diff);}
      caffe_gpu_scal(this->prob_.count(), loss_weight / count, bottom_diff1);
      //caffe_gpu_memcpy(this->prob_.count() * sizeof(Dtype), bottom_diff, bottom_diff1);
    } else {//LOG(INFO) << "loss_weight = " << loss_weight << ", outer_num = " << this->outer_num_;
      if(this->layer_param_.loss_param().down_sgld() == 1){
      caffe_gpu_scal(this->prob_.count(), loss_weight / this->outer_num_, bottom_diff);}
      caffe_gpu_scal(this->prob_.count(), loss_weight / this->outer_num_, bottom_diff1);
      //caffe_gpu_memcpy(this->prob_.count() * sizeof(Dtype), bottom_diff, bottom_diff1);
    }
//LOG(INFO) << "count = " << this->prob_.count();
//for(int i = 0; i < 1; i++){LOG(INFO) << top[0]->cpu_diff()[0];}
  }
}

INSTANTIATE_LAYER_GPU_FUNCS(SoftmaxWithLossBDKLayer);

}  // namespace caffe
