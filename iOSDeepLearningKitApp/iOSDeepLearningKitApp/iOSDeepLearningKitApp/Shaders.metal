//
//  Shaders.metal
//  memkite
//
//  Created by Amund Tveit on 13/08/15.
//  Copyright © 2015 Amund Tveit. All rights reserved.
//

#include <metal_stdlib>
#include <metal_common>
#include <metal_math>
#include <metal_graphics>
#include <metal_matrix>
#include <metal_geometric>
#include <metal_texture>
#include <simd/simd.h> // why?
using namespace metal;

////////////////////////////////
// DATA TYPES
////////////////////////////////

// TODO: perhaps add RGB support as part of this
struct MetalComplexNumberType { // needs to map to float2 in Metal
    float real;
    float imag;
};

// TODO: perhaps add B here? since it is only one value per convolution call (not entire vector)
struct MetalShaderParameters {
    float image_xdim;
    float image_ydim;
    float num_images;
    float filter_xdim; // e.g. 5
    float filter_ydim; // e.g. 5
    float num_filters; // e.g. 20 -> W = 20*1*5*5
    float conv_xdim; // image_xdim - filter_xdim + 1 without striding
    float conv_ydim; // image_ydim - filter_ydim + 1 without striding
    float pool_xdim;
    float pool_ydim;
    float b; // this should probably be an input array, but for now
};

struct MetalMatrixVectorParameters {
    float x_xdim;
    float x_ydim;
    float w_xdim;
    float w_ydim;
    float b_xdim;
    float b_ydim;
    float result_xdim;
    float result_ydim;
};

struct MetalPoolingParameters {
    float kernel_size;
    float pool_stride;
    float pad;
};

struct MetalReluParameters {
    float negative_slope;
};

struct MetalTensorDimensions {
    float n;
    float channels;
    float width;
    float height;
};

struct MetalFCTensorDimensions {
    float rows;
    float cols;
};

struct MetalConvolutionParameters {
    float pad;
    float kernel_size;
    float stride;
};

////////////////////////////////
// SHADER FUNCTIONS
////////////////////////////////

////////////////////////////////////////////////////////////////////////////////////////////


// Returns max(0, X[id]) + negative slope
kernel void rectifier_linear(device float* X [[ buffer(0)]],
                             const device MetalReluParameters* relu_params [[ buffer(1) ]],
                             uint id [[ thread_position_in_grid ]]) {
    float negativeSlope = relu_params[0].negative_slope;
    if (X[id] < 0.0) {
            X[id] = negativeSlope * X[id];
    }
}

kernel void max_pool(device float* result [[ buffer(0) ]],
                     const device float* input [[ buffer(1) ]],
                     const device MetalShaderParameters* size_params [[ buffer(2) ]],
                     const device MetalPoolingParameters* pooling_params [[ buffer(3) ]],
                     uint id [[ thread_position_in_grid ]]) {
    int channels = int(size_params[0].num_filters);
    int in_width = int(size_params[0].image_xdim);
    int in_height = int(size_params[0].image_ydim);

    float kernel_size = float(pooling_params[0].kernel_size);
    int pool_stride = int(pooling_params[0].pool_stride);
    int pad = int(pooling_params[0].pad);

    int out_width = int(size_params[0].pool_xdim);
    int out_height = int(size_params[0].pool_ydim);

    int i = (id / out_height) % out_width;
    int j = id % out_height;
    int n = id / (channels * out_width * out_height);
    int c = (id / (out_width * out_height)) % channels;
    int wstart = i * pool_stride - pad;
    int hstart = j * pool_stride - pad;
    int wend = fmin(wstart + kernel_size, in_width + pad);
    int hend = fmin(hstart + kernel_size, in_height + pad);
    wstart = fmax(0.0, wstart);
    hstart = fmax(0.0, hstart);
    thread float pool = -100000.0;
    for (int ii = wstart; ii < wend; ++ii) {
        for (int jj = hstart; jj < hend; ++jj) {
            pool = fmax(pool, input[(n * channels * in_height + c * in_height + ii) * in_width + jj]);
        }
    }
    result[id] = pool;
}

kernel void avg_pool(device float* result [[ buffer(0) ]],
                     const device float* input [[ buffer(1) ]],
                     const device MetalShaderParameters* size_params [[ buffer(2) ]],
                     const device MetalPoolingParameters* pooling_params [[ buffer(3) ]],
                     uint id [[ thread_position_in_grid ]]) {
    int channels = int(size_params[0].num_filters);
    int in_width = int(size_params[0].image_xdim);
    int in_height = int(size_params[0].image_ydim);

    float kernel_size = float(pooling_params[0].kernel_size);
    int pool_stride = int(pooling_params[0].pool_stride);
    int pad = int(pooling_params[0].pad);

    int out_width = int(size_params[0].pool_xdim);
    int out_height = int(size_params[0].pool_ydim);

    int i = (id / out_height) % out_width;
    int j = id % out_height;
    int n = id / (channels * out_width * out_height);
    int c = (id / (out_width * out_height)) % channels;
    int wstart = i * pool_stride - pad;
    int hstart = j * pool_stride - pad;
    int wend = fmin(wstart + kernel_size, in_width + pad);
    int hend = fmin(hstart + kernel_size, in_height + pad);
    float pool_size = (hend - hstart) * (wend - wstart);
    wstart = fmax(0.0, wstart);
    hstart = fmax(0.0, hstart);
    thread float pool = 0.0;
    for (int ii = wstart; ii < wend; ++ii) {
        for (int jj = hstart; jj < hend; ++jj) {
            pool += input[(n * channels * in_height + c * in_height + ii) * in_width + jj];
        }
    }
    pool /= pool_size;
    result[id] = pool;
}

kernel void im2col(const device float* convolution_input [[ buffer(0)]],
                   const device MetalTensorDimensions* tensor_dimensions [[ buffer(1) ]],
                   const device MetalConvolutionParameters* convolution_params [[ buffer(2) ]],
                   device float* col_output [[ buffer(3) ]],
                   uint id [[ thread_position_in_grid ]]) {
    //int num = int(tensor_dimensions[0].n);
    int channels_in = int(tensor_dimensions[0].channels);
    int in_width = int(tensor_dimensions[0].width);
    int in_height = int(tensor_dimensions[0].height);

    int channels_col = int(tensor_dimensions[2].channels);
    int width_col = int(tensor_dimensions[2].width);
    int height_col = int(tensor_dimensions[2].height);


    // 1. do an im2col transformation
    int pad = int(convolution_params[0].pad);
    int kernel_size = int(convolution_params[0].kernel_size);

    int n = id / (channels_col * height_col * width_col);
    int c = (id / (width_col * height_col)) % channels_col;
    int h = (id / width_col) % height_col;
    int w = id % width_col;
    int w_offset = c % kernel_size;
    int h_offset = (c / kernel_size) % kernel_size;
    int h_pad = h - pad + h_offset;
    int w_pad = w - pad + w_offset;
    int c_im = c / (kernel_size * kernel_size);
    if (h_pad >= 0 && h_pad < in_height && w_pad >= 0 && w_pad < in_width) {
        col_output[id] = convolution_input[(n * channels_in * in_height + c_im * in_height + h_pad) * in_width + w_pad];
    } else {
//        if (w_pad < 0 && h_pad >= 0) {
//            col_output[id] = 1.0;
//        }
        col_output[id] = 0.0f;
    }
}

// Tensor dimensions = { input_dimensions, weight_dimensions, col_dimensions, result_dimensions }
kernel void convolution_layer(device float* result [[ buffer(0) ]],
                              const device float* weights [[ buffer(1)]],
                              const device MetalTensorDimensions* tensor_dimensions [[ buffer(2) ]],
                              const device float* col_output [[ buffer(3) ]],
                              const device float* bias [[ buffer(4) ]],
                              uint id [[ thread_position_in_grid ]]) {
    //int num = int(tensor_dimensions[2].n);
    int channels_col = int(tensor_dimensions[2].channels);
    int width_col = int(tensor_dimensions[2].width);
    int height_col = int(tensor_dimensions[2].height);
    
    int channels_out = int(tensor_dimensions[3].channels);
    int width_out = int(tensor_dimensions[3].width);
    int height_out = int(tensor_dimensions[3].height);
    
    int n = id / (channels_out * height_out * width_out);
    int a = (id / (height_out * width_out)) % channels_out;
    int b = id % (height_out * width_out);
    
    float foo =  bias[a];
    
    int base = n * channels_col * width_col * height_col + b;
    int base_w = a * channels_col;
    int size = width_col * height_col;
    for (int c = 0; c < channels_col; c+=4) {
        float4 out = float4(col_output[c * size + base],
                      col_output[(c+1) * size + base],
                      col_output[(c+2) * size + base],
                      col_output[(c+3) * size + base]);
        float4 w = float4(weights[base_w+c],
                    weights[base_w+c+1],
                    weights[base_w+c+2],
                    weights[base_w+c+3]);
        foo += dot(out, w);
    }
    
    result[id] = foo;
}

// Tensor dimensions = { input_dimensions, weight_dimensions, col_dimensions, result_dimensions }
kernel void fast_convolution_layer(device float* result [[ buffer(0) ]],
                              const device float* weights [[ buffer(1)]],
                              const device MetalTensorDimensions* tensor_dimensions [[ buffer(2) ]],
                              const device float* input [[ buffer(3) ]],
                              const device float* bias [[ buffer(4) ]],
                              uint id [[ thread_position_in_grid ]]) {
    //int num = int(tensor_dimensions[2].n);
    int channels_in = int(tensor_dimensions[0].channels);
    int width_in = int(tensor_dimensions[0].width);
    int height_in = int(tensor_dimensions[0].height);
    
    int channels_out = int(tensor_dimensions[3].channels);
    int width_out = int(tensor_dimensions[3].width);
    int height_out = int(tensor_dimensions[3].height);
    
    int width_kernel = int(tensor_dimensions[1].width);
    int height_kernel = int(tensor_dimensions[1].height);
    int h_offset = (height_in - height_out) / 2;
    int w_offset = (width_in - width_out) / 2;
    
    int n = id / (channels_out * height_out * width_out);
    int a = (id / (height_out * width_out)) % channels_out;
    int b = id % (height_out * width_out);
    int result_width = w_offset + (b % width_out);
    int result_height = h_offset + (b / width_out);
    
    float foo =  bias[a];
    
    // TODO(Neil): add SIMD 4-way operations to speed up further
    // TODO(Neil): avoid 3 stack loop
    for (int c = 0; c < channels_in; c++) {
        for (int kh = -height_kernel / 2; kh <= height_kernel / 2; kh++) {
            for (int kw = -width_kernel / 2; kw <= width_kernel / 2; kw++) {
                float val = 0;
                int w = result_width + kw;
                int h = result_height + kh;
                
                // TODO: extend original image a little bit to avoid checking here
                if (w >= 0 && w < width_in && h >= 0 && h < height_in) {
                    val = input[(n * channels_in * width_in + c * width_in) * height_in + h * width_in + w];
                }
                foo += val * weights[(a * channels_in * width_kernel + c * width_kernel) * height_kernel + (kh + height_kernel / 2) * width_kernel + kw + width_kernel / 2];
            }
        }
    }
    
    
    result[id] = foo;
}


kernel void fc_layer(device float* result [[ buffer(0) ]],
                              const device float* weights [[ buffer(1)]],
                              const device MetalFCTensorDimensions* tensor_dimensions [[ buffer(2) ]],
                              const device float* input [[ buffer(3) ]],
                              const device float* bias [[ buffer(4) ]],
                              uint id [[ thread_position_in_grid ]]) {
    int input_dim = int(tensor_dimensions[0].cols);
    int output_dim = int(tensor_dimensions[1].rows);
    
    int r = id / output_dim;
    int c = id % output_dim;
    
    thread float foo = bias[c];
    int base = r * input_dim;
    for (int i = 0; i < input_dim; ++i) {
        foo += input[base + i] * weights[c * input_dim + i];
    }
    
    result[id] = foo;
}


