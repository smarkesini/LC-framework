/*
This file is part of the LC framework for synthesizing high-speed parallel lossless and error-bounded lossy data compression and decompression algorithms for CPUs and GPUs.

BSD 3-Clause License

Copyright (c) 2021-2024, Noushin Azami, Alex Fallin, Brandon Burtchell, Andrew Rodriguez, Benila Jerald, Yiqian Liu, and Martin Burtscher
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

URL: The latest version of this code is available at https://github.com/burtscher/LC-framework.

Sponsor: This code is based upon work supported by the U.S. Department of Energy, Office of Science, Office of Advanced Scientific Research (ASCR), under contract DE-SC0022223.
*/


#define NDEBUG

using byte = unsigned char;
static const int CS = 1024 * 16;  // chunk size (in bytes) [must be multiple of 8]
//static const int CS = 384*352 / 8;  // fraction of detector size 
//static const int CS = 384*352 / 16;

//static const int TPB = 768;  // threads per block [must be power of 2 and at least 128]
//static const int TPB = 512;  // threads per block [must be power of 2 and at least 128]
//static const int TPB = 768;  // threads per block [must be power of 2 and at least 128]

//static const int TPB = 768-32;  // threads per block [must be power of 2 and at least 128]

static const int TPB = 512-32;  // threads per block [must be power of 2 and at least 128]

#if defined(__AMDGCN_WAVEFRONT_SIZE) && (__AMDGCN_WAVEFRONT_SIZE == 64)
#define WS 64
#else
#define WS 32
#endif

#define NUMSTREAMS 4
#define NUMSEGS 1

#include <string>
#include <cmath>
#include <cassert>
#include <stdexcept>
#include <cuda.h>
#include "include/sum_reduction.h"
#include "include/max_scan.h"
#include "include/prefix_sum.h"
#include "preprocessors/d_QUANT_ABS_0_f32.h"
#include "components/d_BIT_4.h"
#include "components/d_RZE_1.h"


// copy (len) bytes from shared memory (source) to global memory (destination)
// source must we word aligned
static inline __device__ void s2g(void* const __restrict__ destination, const void* const __restrict__ source, const int len)
{
  const int tid = threadIdx.x;
  const byte* const __restrict__ input = (byte*)source;
  byte* const __restrict__ output = (byte*)destination;
  if (len < 128) {
    if (tid < len) output[tid] = input[tid];
  } else {
    const int nonaligned = (int)(size_t)output;
    const int wordaligned = (nonaligned + 3) & ~3;
    const int linealigned = (nonaligned + 127) & ~127;
    const int bcnt = wordaligned - nonaligned;
    const int wcnt = (linealigned - wordaligned) / 4;
    const int* const __restrict__ in_w = (int*)input;
    if (bcnt == 0) {
      int* const __restrict__ out_w = (int*)output;
      if (tid < wcnt) out_w[tid] = in_w[tid];
      for (int i = tid + wcnt; i < len / 4; i += TPB) {
        out_w[i] = in_w[i];
      }
      if (tid < (len & 3)) {
        const int i = len - 1 - tid;
        output[i] = input[i];
      }
    } else {
      const int shift = bcnt * 8;
      const int rlen = len - bcnt;
      int* const __restrict__ out_w = (int*)&output[bcnt];
      if (tid < bcnt) output[tid] = input[tid];
      if (tid < wcnt) out_w[tid] = __funnelshift_r(in_w[tid], in_w[tid + 1], shift);
      for (int i = tid + wcnt; i < rlen / 4; i += TPB) {
        out_w[i] = __funnelshift_r(in_w[i], in_w[i + 1], shift);
      }
      if (tid < (rlen & 3)) {
        const int i = len - 1 - tid;
        output[i] = input[i];
      }
    }
  }
}


static __device__ int g_chunk_counter[NUMSTREAMS];


static __global__ void d_reset(const short stream_num)
{
  g_chunk_counter[stream_num] = 0;
}


static inline __device__ void propagate_carry(const int value, const int chunkID, volatile int* const __restrict__ fullcarry, int* const __restrict__ s_fullc)
{
  if (threadIdx.x == TPB - 1) {  // last thread
    fullcarry[chunkID] = (chunkID == 0) ? value : -value;
  }

  if (chunkID != 0) {
    if (threadIdx.x + WS >= TPB) {  // last warp
      const int lane = threadIdx.x % WS;
      const int cidm1ml = chunkID - 1 - lane;
      int val = -1;
      __syncwarp();  // not optional
      do {
        if (cidm1ml >= 0) {
          val = fullcarry[cidm1ml];
        }
      } while ((__any_sync(~0, val == 0)) || (__all_sync(~0, val <= 0)));
#if defined(WS) && (WS == 64)
      const long long mask = __ballot_sync(~0, val > 0);
      const int pos = __ffsll(mask) - 1;
#else
      const int mask = __ballot_sync(~0, val > 0);
      const int pos = __ffs(mask) - 1;
#endif
      int partc = (lane < pos) ? -val : 0;
#if defined(__CUDA_ARCH__) && (__CUDA_ARCH__ >= 800)
      partc = __reduce_add_sync(~0, partc);
#else
      partc += __shfl_xor_sync(~0, partc, 1);
      partc += __shfl_xor_sync(~0, partc, 2);
      partc += __shfl_xor_sync(~0, partc, 4);
      partc += __shfl_xor_sync(~0, partc, 8);
      partc += __shfl_xor_sync(~0, partc, 16);
#endif
      if (lane == pos) {
        const int fullc = partc + val;
        fullcarry[chunkID] = fullc + value;
        *s_fullc = fullc;
      }
    }
  }
}


#if defined(__CUDA_ARCH__) && (__CUDA_ARCH__ == 800)
static __global__ __launch_bounds__(TPB, 3)
#else
static __global__ __launch_bounds__(TPB, 2)
#endif
  void d_encode(const byte* const __restrict__ input, const int insize, byte* const __restrict__ output, int* const __restrict__ outsize, int* const __restrict__ fullcarry, const short stream_num)
{
  // allocate shared memory buffer
  __shared__ long long chunk [3 * (CS / sizeof(long long))];

  // split into 3 shared memory buffers
  byte* in = (byte*)&chunk[0 * (CS / sizeof(long long))];
  byte* out = (byte*)&chunk[1 * (CS / sizeof(long long))];
  byte* const temp = (byte*)&chunk[2 * (CS / sizeof(long long))];

  // initialize
  const int tid = threadIdx.x;
  const int last = 3 * (CS / sizeof(long long)) - 2 - WS;
  const int chunks = (insize + CS - 1) / CS;  // round up
  int* const head_out = (int*)output;
  unsigned short* const size_out = (unsigned short*)&head_out[1];
  byte* const data_out = (byte*)&size_out[chunks];

  // loop over chunks
  do {
    // assign work dynamically
    if (tid == 0) chunk[last] = atomicAdd(&g_chunk_counter[stream_num], 1);
    __syncthreads();  // chunk[last] produced, chunk consumed

    // terminate if done
    const int chunkID = chunk[last];
    const int base = chunkID * CS;
    if (base >= insize) break;

    // load chunk
    const int osize = min(CS, insize - base);
    long long* const input_l = (long long*)&input[base];
    long long* const out_l = (long long*)out;
    for (int i = tid; i < osize / 8; i += TPB) {
      out_l[i] = input_l[i];
    }
    const int extra = osize % 8;
    if (tid < extra) out[osize - extra + tid] = input[base + osize - extra + tid];

    // encode chunk
    __syncthreads();  // chunk produced, chunk[last] consumed
    int csize = osize;
    bool good = true;
    if (good) {
      byte* tmp = in; in = out; out = tmp;
      good = d_BIT_4(csize, in, out, temp);
     __syncthreads();
    }
    if (good) {
      byte* tmp = in; in = out; out = tmp;
      good = d_RZE_1(csize, in, out, temp);
     __syncthreads();
    }

    // handle carry
    if (!good || (csize >= osize)) csize = osize;
    propagate_carry(csize, chunkID, fullcarry, (int*)temp);

    // reload chunk if incompressible
    if (tid == 0) size_out[chunkID] = csize;
    if (csize == osize) {
      // store original data
      long long* const out_l = (long long*)out;
      for (int i = tid; i < osize / 8; i += TPB) {
        out_l[i] = input_l[i];
      }
      const int extra = osize % 8;
      if (tid < extra) out[osize - extra + tid] = input[base + osize - extra + tid];
    }
    __syncthreads();  // "out" done, temp produced

    // store chunk
    const int offs = (chunkID == 0) ? 0 : *((int*)temp);
    s2g(&data_out[offs], out, csize);

    // finalize if last chunk
    if ((tid == 0) && (base + CS >= insize)) {
      // output header
      head_out[0] = insize;
      // compute compressed size
      *outsize = &data_out[fullcarry[chunkID]] - output;
    }
  } while (true);
}


struct GPUTimer
{
  cudaEvent_t beg, end;
  GPUTimer() {cudaEventCreate(&beg); cudaEventCreate(&end);}
  ~GPUTimer() {cudaEventDestroy(beg); cudaEventDestroy(end);}
  void start() {cudaEventRecord(beg, 0);}
  double stop() {cudaEventRecord(end, 0); cudaEventSynchronize(end); float ms; cudaEventElapsedTime(&ms, beg, end); return 0.001 * ms;}
};


static void CheckCuda(const int line)
{
  cudaError_t e;
  cudaDeviceSynchronize();
  if (cudaSuccess != (e = cudaGetLastError())) {
    fprintf(stderr, "CUDA error %d on line %d: %s\n\n", e, line, cudaGetErrorString(e));
    throw std::runtime_error("LC error");
  }
}


int main(int argc, char* argv [])
{
  printf("GPU LC 1.2 Algorithm: QUANT_ABS_0_f32 BIT_4 RZE_1\n");
  printf("Copyright 2024 Texas State University\n\n");
  // read input from file
  //if (argc < 3) {printf("USAGE: %s input_file_name compressed_file_name [performance_analysis (y)]\n\n", argv[0]); return -1;}
  if (argc < 4) {
    printf("USAGE: %s input_file_name compressed_file_name num_events [performance_analysis (y)]\n\n",
           argv[0]); 
    return -1;
  }
  char* leftover;
  int num_events = strtol(argv[3], &leftover, 10);
  FILE* const fin = fopen(argv[1], "rb");
  // read input from file
  fseek(fin, 0, SEEK_END);
  const int fsize = ftell(fin);  assert(fsize > 0);
  byte* const input = new byte [fsize];
  fseek(fin, 0, SEEK_SET);
  const int original_insize = fread(input, 1, fsize, fin);  assert(original_insize == fsize);
  fclose(fin);
  printf("original size: %d bytes\n", original_insize);
  printf("original size: %d bytes\n", original_insize);
  printf("num events: %d \n", num_events);

  const int insize = original_insize / num_events;
  printf("Bytes per event: %d\n", insize);

  // Check if the third argument is "y" to enable performance analysis
  char* perf_str = argv[4];
  //char* perf_str = argv[3];
  bool perf = false;
  if (perf_str != nullptr && strcmp(perf_str, "y") == 0) {
    perf = true;
  } else if (perf_str != nullptr && strcmp(perf_str, "y") != 0) {
    fprintf(stderr, "ERROR: Invalid argument. Use 'y' or nothing.\n");
    throw std::runtime_error("LC error");
  }

  // get GPU info
  cudaSetDevice(0);
  cudaDeviceProp deviceProp;
  cudaGetDeviceProperties(&deviceProp, 0);
  if ((deviceProp.major == 9999) && (deviceProp.minor == 9999)) {fprintf(stderr, "ERROR: no CUDA capable device detected\n\n"); throw std::runtime_error("LC error");}
  //const int SMs = deviceProp.multiProcessorCount;
  //const int mTpSM = deviceProp.maxThreadsPerMultiProcessor;
  const int blocks = 24;//SMs * (mTpSM / TPB);
  //const int blocks = 24;//SMs * (mTpSM / TPB);

  const int chunks = (insize + CS - 1) / CS;  // round up
  CheckCuda(__LINE__);
  const int maxsize = 3 * sizeof(int) + chunks * sizeof(short) + chunks * CS;

  cudaStream_t streams[NUMSTREAMS];

  // allocate GPU memory
  byte* dencoded[NUMSTREAMS];
  byte* d_input[NUMSTREAMS];
  byte* d_encoded[NUMSTREAMS];
  int* d_encsize[NUMSTREAMS];
  byte* dpreencdata[NUMSTREAMS];
  //int dpreencsize = insize; // Assume same input size for every event/stream
  int dpreencsize = insize/NUMSEGS; // Divide frames into segments 
  int evts_per_stream = num_events / NUMSTREAMS * NUMSEGS;
  for (size_t i=0; i < NUMSTREAMS; ++i) {
    cudaMallocHost((void **)&dencoded[i], maxsize);
    //cudaMalloc((void **)&d_input[i], insize*evts_per_stream);
    //cudaMemcpy(d_input[i], input + i*insize*evts_per_stream, insize*evts_per_stream, cudaMemcpyHostToDevice);
    cudaMalloc((void **)&d_input[i], dpreencsize*evts_per_stream);
    //cudaMemcpy(d_input[i], input + i*dpreencsize*evts_per_stream, insize*evts_per_stream, cudaMemcpyHostToDevice);
    cudaMemcpy(d_input[i], input + i*dpreencsize*evts_per_stream, dpreencsize*evts_per_stream, cudaMemcpyHostToDevice);
    cudaMalloc((void **)&d_encoded[i], maxsize);
    cudaMalloc((void **)&d_encsize[i], sizeof(int));
    CheckCuda(__LINE__);
    //cudaMalloc((void **)&dpreencdata[i], insize*evts_per_stream);
    //cudaMemcpy(dpreencdata[i], d_input[i], insize*evts_per_stream, cudaMemcpyDeviceToDevice);
    cudaMalloc((void **)&dpreencdata[i], dpreencsize*evts_per_stream);
    cudaMemcpy(dpreencdata[i], d_input[i], dpreencsize*evts_per_stream, cudaMemcpyDeviceToDevice);
    cudaStreamCreate(&streams[i]);
  }

  if (perf) {
    //int* d_fullcarry[NUMSTREAMS];
    for (size_t i=0; i < NUMSTREAMS; ++i) {
      byte* d_preencdata;
      cudaMalloc((void **)&d_preencdata, insize);
      cudaMemcpy(d_preencdata, d_input[i], insize, cudaMemcpyDeviceToDevice);
      int dpreencsize = insize;
      double paramv[] = {3}; 
      d_QUANT_ABS_0_f32(dpreencsize, d_preencdata, 1, paramv);
//      d_QUANT_ABS_0_f32(dpreencsize, d_preencdata, 1, paramv);
//      byte* d_ptr = dpreencdata[i] + dpreencsize*evt;
//      d_QUANT_ABS_0_f32_stream(dpreencsize, d_ptr, 1, paramv, streams[i]);

      cudaFree(d_preencdata);
    }
  }


  int* d_fullcarry[NUMSTREAMS];


  for (size_t i=0; i < NUMSTREAMS; ++i)
    cudaMalloc((void **)&d_fullcarry[i], chunks * sizeof(int));

  cudaDeviceSynchronize();
  GPUTimer dtimer;
  double paramv[] = {3};
  dtimer.start();

  for (size_t evt=0; evt < evts_per_stream; ++evt) {
    for (size_t i=0; i < NUMSTREAMS; ++i) {
      byte* d_ptr = dpreencdata[i] + dpreencsize*evt;
      //d_QUANT_ABS_0_f32(dpreencsize, d_ptr, 1, paramv);
      d_QUANT_ABS_0_f32_stream(dpreencsize, d_ptr, 1, paramv, streams[i]);

      d_reset<<<1, 1, 0, streams[i]>>>(i);
      //cudaMemset(d_fullcarry[i], 0, chunks * sizeof(byte));
      cudaMemsetAsync(d_fullcarry[i], 0, chunks * sizeof(byte), streams[i]);
      d_encode<<<blocks, TPB, 0, streams[i]>>>(dpreencdata[i]+dpreencsize*evt, dpreencsize, d_encoded[i], d_encsize[i], d_fullcarry[i], i);
    }
  }
  cudaDeviceSynchronize();
    //cudaMalloc((void **)&d_fullcarry[i], chunks * sizeof(int));

  double runtime = dtimer.stop();

  for (size_t i=0; i < NUMSTREAMS; ++i)
    cudaFree(d_fullcarry[i]);

  // get encoded GPU result
  //int dencsize = 0;
  //cudaMemcpy(&dencsize, d_encsize, sizeof(int), cudaMemcpyDeviceToHost);
  //cudaMemcpy(dencoded, d_encoded, dencsize, cudaMemcpyDeviceToHost);
  //printf("encoded size: %d bytes\n", dencsize);
  //CheckCuda(__LINE__);

  //const float CR = (100.0 * dencsize) / insize;
  //printf("ratio: %6.2f%% %7.3fx\n", CR, 100.0 / CR);

  // calculate theoretical occupancy
  int maxActiveBlocks;
  cudaOccupancyMaxActiveBlocksPerMultiprocessor( &maxActiveBlocks, 
                                                 d_encode, TPB, 
                                                 0);

  int device;
  cudaDeviceProp props;
  cudaGetDevice(&device);
  cudaGetDeviceProperties(&props, device);

  float occupancy = (maxActiveBlocks * TPB / props.warpSize) / 
                    (float)(props.maxThreadsPerMultiProcessor / 
                            props.warpSize);

  printf("Launched blocks of size %d. Theoretical occupancy: %f\nMax active blocks:%d\n", 
         TPB, occupancy, maxActiveBlocks);

  if (perf) {
    printf("encoding time: %.6f s\n", runtime);
    double throughput = insize * 0.000000001 / runtime;
    printf("original size: %d \n", original_insize );

    printf("encoding throughput: %8.3f Gbytes/s\n", original_insize * 0.000000001 / runtime);
    printf("encoding throughput: %8.3f Gbytes/s\n", throughput*NUMSTREAMS*evts_per_stream/NUMSEGS);
    printf("\tNumber of streams: %d\n", NUMSTREAMS);
    printf("\tEvents per stream: %d\n", evts_per_stream);
    printf("\tNumber of Segments: %d\n", NUMSEGS);


    CheckCuda(__LINE__);
  }

  // write to file
  //FILE* const fout = fopen(argv[2], "wb");
  //fwrite(dencoded, 1, dencsize, fout);
  //fclose(fout);

  // clean up GPU memory
  for (size_t i=0; i < NUMSTREAMS; ++i) {
    cudaFree(d_input[i]);
    cudaFree(d_encoded[i]);
    cudaFree(d_encsize[i]);
    CheckCuda(__LINE__);
  }

  // clean up
  delete [] input;
  cudaFreeHost(dencoded);
  return 0;
}
