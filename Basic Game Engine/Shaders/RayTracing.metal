//
/**
 * Copyright (c) 2018 Razeware LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
 * distribute, sublicense, create a derivative work, and/or sell copies of the
 * Software in any work that is designed, intended, or marketed for pedagogical or
 * instructional purposes related to programming, coding, application development,
 * or information technology.  Permission for such use, copying, modification,
 * merger, publication, distribution, sublicensing, creation of derivative works,
 * or sale is expressly withheld.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

// Add structs here

struct Ray {
    packed_float3 origin;
    float minDistance;
    packed_float3 direction;
    float maxDistance;
    float3 color = 0;
    float3 indirectColor = 0;
    float3 prevDirection;
    float3 offset;
};

struct Intersection {
  float distance;
  int primitiveIndex;
  float2 coordinates;
};

constant float PI = 3.14159265;
constexpr sampler s__(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
constexpr sampler s_(coord::normalized, address::repeat, filter::nearest, mip_filter::none);

constant unsigned int primes[] = {
    2,   3,  5,  7,
    11, 13, 17, 19,
    23, 29, 31, 37,
    41, 43, 47, 53,
};

constant int AMBIENT_DIR_COUNT = 6;
constant float3 ambientCubeDir[] = {
    float3(0.7071, 0, 0.7071),
    float3(0, 1, 0),
    float3(0.7071, 0, -0.7071),
    float3(-0.7071, 0, 0.7071),
    float3(0, -1, 0),
    float3(-0.7071, 0, -0.7071)
};
constant float infDist = 10000;

float3 sphericalFibonacci(float i_, float n) {
    float i = i_ + 0.5;
    const float PHI = 1.6180339;
#   define madfrac(A, B) ((A)*(B)-floor((A)*(B)))
    float phi = 2.0 * PI * madfrac(i, PHI - 1);
    float cosTheta = 1.0 - (2.0 * i + 1.0) * (1.0 / n);
    float sinTheta = sqrt(saturate(1.0 - cosTheta * cosTheta));

    return float3(
        cos(phi) * sinTheta,
        sin(phi) * sinTheta,
        cosTheta);

#   undef madfrac
}

uint3 indexToGridPos(int index, int width, int height){
    int indexD = index / (width * height);
    int indexH = (index % (width * height)) / width;
    int indexW = (index % (width * height)) % width;
    return uint3(indexW, indexH, indexD);
}

uint2 indexToTexPos(int index, int width, int height){
    int indexD = index / (width * height);
    int indexH = (index % (width * height));
    return uint2(indexH, indexD);
}

/*
 float2 pixel = float2(tid.x % uniforms.probeWidth, tid.y % uniforms.probeHeight);
//   float2 r = random[(tid.y % 16) * 16 + (tid.x % 16)];
//      r = 0;
//    pixel += r;
 float2 uv = (float2)pixel / float2(uniforms.probeWidth, uniforms.probeHeight);
 */

kernel void primaryRays(constant Uniforms_ & uniforms [[buffer(0)]],
                        device Ray *rays [[buffer(1)]],
                        device float2 *random [[buffer(2)]],
                        device LightProbe *probes [[buffer(3)]],
                        device float3 *probeDirections [[buffer(4)]],
                        texture2d<float, access::write> t [[texture(0)]],
                        uint2 tid [[thread_position_in_grid]])
{
  if (tid.x < uniforms.width && tid.y < uniforms.height && uniforms.frameIndex) {
      float2 pixel = float2(tid.x % uniforms.probeWidth, tid.y % uniforms.probeHeight);
     //   float2 r = random[(tid.y % 16) * 16 + (tid.x % 16)];
     //      r = 0;
     //    pixel += r;
      float2 uv = (float2)pixel / float2(uniforms.probeWidth, uniforms.probeHeight);
    uv = uv * 2.0 - 1.0;
//    constant Camera_ & camera = uniforms.camera;
    unsigned int rayIdx = tid.y * uniforms.width + tid.x;
    device Ray & ray = rays[rayIdx];
      
         int index = tid.x / uniforms.probeWidth;
       ray.origin = probes[index].location + probes[index].offset;
  //    ray.probeIndex = index;
  //    ray.direction = normalize(float3(0, 1, 0));
      int rayDirIndex = tid.y*uniforms.probeWidth + tid.x % uniforms.probeWidth;
      ray.direction = probeDirections[rayDirIndex*((uniforms.frameIndex + 1) % 4000)];
  //    ray.direction = sphericalFibonacci(rayDirIndex, uniforms.probeWidth * uniforms.probeHeight);
//      ray.direction = normalize(ray.direction);
//    ray.origin = camera.position;
//    ray.direction = normalize(uv.x * camera.right + uv.y * camera.up + camera.forward);
    ray.minDistance = 0;
    ray.maxDistance = INFINITY;
    ray.color = float3(0.0);
//    t.write(float4(0.0), tid);
  }
}

// Interpolates vertex attribute of an arbitrary type across the surface of a triangle
// given the barycentric coordinates and triangle index in an intersection struct
template<typename T>
inline T interpolateVertexAttribute(device T *attributes, Intersection intersection) {
  float3 uvw;
  uvw.xy = intersection.coordinates;
  uvw.z = 1.0 - uvw.x - uvw.y;
  unsigned int triangleIndex = intersection.primitiveIndex;
  T T0 = attributes[triangleIndex * 3 + 0];
  T T1 = attributes[triangleIndex * 3 + 1];
  T T2 = attributes[triangleIndex * 3 + 2];
  return uvw.x * T0 + uvw.y * T1 + uvw.z * T2;
}

// Uses the inversion method to map two uniformly random numbers to a three dimensional
// unit hemisphere where the probability of a given sample is proportional to the cosine
// of the angle between the sample direction and the "up" direction (0, 1, 0)
inline float3 sampleCosineWeightedHemisphere(float2 u) {
  float phi = 2.0f * M_PI_F * u.x;
  
  float cos_phi;
  float sin_phi = sincos(phi, cos_phi);
  
  float cos_theta = sqrt(u.y);
  float sin_theta = sqrt(1.0f - cos_theta * cos_theta);
  
  return float3(sin_theta * cos_phi, cos_theta, sin_theta * sin_phi);
}

// Maps two uniformly random numbers to the surface of a two-dimensional area light
// source and returns the direction to this point, the amount of light which travels
// between the intersection point and the sample point on the light source, as well
// as the distance between these two points.
inline void sampleAreaLight(constant AreaLight & light,
                            float2 u,
                            float3 position,
                            thread float3 & lightDirection,
                            thread float3 & lightColor,
                            thread float & lightDistance)
{
  // Map to -1..1
  u = u * 2.0f - 1.0f;
  
  // Transform into light's coordinate system
  float3 samplePosition = light.position +
  light.right * u.x +
  light.up * u.y;
  
  // Compute vector from sample point on light source to intersection point
  lightDirection = samplePosition - position;
  
  lightDistance = length(lightDirection);
  
  float inverseLightDistance = 1.0f / max(lightDistance, 1e-3f);
  
  // Normalize the light direction
  lightDirection *= inverseLightDistance;
  
  // Start with the light's color
  lightColor = light.color;
  
  // Light falls off with the inverse square of the distance to the intersection point
  lightColor *= (inverseLightDistance * inverseLightDistance);
  
  // Light also falls off with the cosine of angle between the intersection point and
  // the light source
  lightColor *= saturate(dot(-lightDirection, light.forward));
}

// Aligns a direction on the unit hemisphere such that the hemisphere's "up" direction
// (0, 1, 0) maps to the given surface normal direction
inline float3 alignHemisphereWithNormal(float3 sample, float3 normal) {
  // Set the "up" vector to the normal
  float3 up = normal;
  
  // Find an arbitrary direction perpendicular to the normal. This will become the
  // "right" vector.
  float3 right = normalize(cross(normal, float3(0.0072f, 1.0f, 0.0034f)));
  
  // Find a third vector perpendicular to the previous two. This will be the
  // "forward" vector.
  float3 forward = cross(right, up);
  
  // Map the direction on the unit hemisphere to the coordinate system aligned
  // with the normal.
  return sample.x * right + sample.y * up + sample.z * forward;
}

constant float2 invPi_ = float2(0.15915, 0.31831);

float2 sampleSphericalMap__(float3 dir) {
    float3 v = normalize(dir);
    float2 uv = float2(atan(-v.z/v.x), acos(v.y));
    if (v.x < 0) {
        uv.x += M_PI_F;
    }
    if (v.x >= 0 && -v.z < 0) {
        uv.x += 2*M_PI_F;
    }
    uv *= invPi_;
    return uv;
}

float2 octWrap( float2 v ) {
    return ( 1.0 - abs( v.yx ) ) * ( (v.x >= 0.0 && v.y >=0) ? 1.0 : -1.0 );
}

float signNotZero(float k) {
    return (k >= 0.0) ? 1.0 : -1.0;
}

float2 signNotZero(float2 v) {
    return float2(signNotZero(v.x), signNotZero(v.y));
}
 
float2 octEncode( float3 v ) {
    float l1norm = abs(v.x) + abs(v.y) + abs(v.z);
    float2 result = v.xy * (1.0 / l1norm);
    if (v.z < 0.0) {
        result = (1.0 - abs(result.yx)) * signNotZero(result.xy);
    }
    result = result*0.5 + 0.5;
    return result;
}
 
float3 octDecode( float2 f ) {
    f = f * 2.0 - 1.0;
 
    // https://twitter.com/Stubbesaurus/status/937994790553227264
    float3 n = float3( f.x, f.y, 1.0 - abs( f.x ) - abs( f.y ) );
    float t = saturate( -n.z );
    n.xy += (n.x >= 0.0 && n.y >=0) ? -t : t;
    return normalize( n );
}

int gridPosToProbeIndex(float3 pos, LightProbeData_ probe) {
    float3 texPos_ = (pos - probe.gridOrigin)/probe.gridEdge;
    int3 texPos = int3(texPos_);
    return  texPos.x +
            texPos.y * probe.probeCount.x +
            texPos.z * probe.probeCount.x * probe.probeCount.y;
}

float signum__(float v) {
    return v > 0 ? 1.0 : 0.0;
}

void SHProjectLinear__(float3 dir, float coeff[9]) {
    float l0 = 0.282095;
    float l1 = 0.488603;
    float l20 = 1.092548;
    float l21 = 0.315392;
    float l22 = 0.546274;
    float x = dir.x, y = dir.y, z = dir.z;
    
    coeff[0] = l0;
    coeff[1] = y * l1;
    coeff[2] = z * l1;
    coeff[3] = x * l1;
    
    coeff[4] = x * y * l20;
    coeff[5] = y * z * l20;
    coeff[6] = (3*z*z - 1.0) * l21;
    coeff[7] = x * z * l20;
    coeff[8] = (x*x - y*y) * l22;
}

constant float3 probePos[8] = {
    float3(0, 0, 0),
    float3(1, 0, 0),
    float3(0, 1, 0),
    float3(1, 1, 0),
    
    float3(0, 0, 1),
    float3(1, 0, 1),
    float3(0, 1, 1),
    float3(1, 1, 1),
};


float sq_(float s) {
    return s*s;
}

float pow3_(float s) { return s*s*s; }

float3 getDDGI_(float3 position,
                float3 smoothNormal,
                device LightProbe *probes,
                LightProbeData_ probeData,
                texture2d<float, access::sample> octahedralMap,
                texture2d<float, access::sample> radianceMap)
{
    float3 transformedPos = (position - probeData.gridOrigin)/probeData.gridEdge;
    transformedPos -= float3(int3(transformedPos));
    float x = transformedPos.x;
    float y = transformedPos.y;
    float z = transformedPos.z;
    
    float trilinearWeights[8] = {
        (1 - x)*(1 - y)*(1 - z),
        x*(1 - y)*(1 - z),
        (1 - x)*y*(1 - z),
        x*y*(1 - z),

        (1 - x)*(1 - y)*z,
        x*(1 - y)*z,
        (1 - x)*y*z,
        x*y*z,
    };
    
//    for(int i = 0; i < 8; i++) {
//        float3 trueDirectionToProbe = normalize(probePos[i] - transformedPos);
//        float w = max(0.0001, (dot(trueDirectionToProbe, smoothNormal) + 1.0) * 0.5);
//        trilinearWeights[i] *= w*w + 0.2;
//    }
    
    int probeIndex = gridPosToProbeIndex(position, probeData);
    
    ushort2 lightProbeTexCoeff[8] = {
        ushort2(0, 0),
        ushort2(1, 0),
        ushort2(probeData.probeCount.x, 0),
        ushort2(probeData.probeCount.x + 1, 0),
        ushort2(0, 1),
        ushort2(1, 1),
        ushort2(probeData.probeCount.x, 1),
        ushort2(probeData.probeCount.x + 1, 1)
    };
    
    float3 color = 0;
    float shCoeff[9];
    SHProjectLinear__(smoothNormal, shCoeff);
    float aCap[9] = {   3.141593,
                        2.094395, 2.094395, 2.094395,
                        0.785398, 0.785398, 0.785398, 0.785398, 0.785398, };
    for (int iCoeff = 0; iCoeff < 8; iCoeff++) {
        float3 color_ = 0;
        int index = probeIndex +
                    lightProbeTexCoeff[iCoeff][0] +
                    lightProbeTexCoeff[iCoeff][1] * probeData.probeGridWidth * probeData.probeGridHeight;
        device LightProbe &probe = probes[index];
        float normalBias = 0.1;
        float depthBias = 0.05;
        float3 dirFromProbe = normalize(position - (probe.location + probe.offset));
        float dotPN = dot(dirFromProbe, smoothNormal);
        if (dotPN > 0)
            continue;
        
        float3 newPosition = position + normalBias * smoothNormal;
        dirFromProbe = normalize(newPosition - (probe.location + probe.offset));
        float distToProbe = length(newPosition - (probe.location + probe.offset));
        uint2 texPos = indexToTexPos(index, probeData.probeGridWidth, probeData.probeGridHeight);
        
        int shadowProbeReso = 64;
        int3 probeCount = probeData.probeCount;
        float2 encodedUV = octEncode(dirFromProbe);
        float2 encodedUV_ = octEncode(smoothNormal);
        float minimumUV = 1.0/shadowProbeReso;
        if (encodedUV.x < minimumUV)
            encodedUV.x += minimumUV;
        if (encodedUV.x > 1-minimumUV)
            encodedUV.x -= minimumUV;
        if (encodedUV.y < minimumUV)
            encodedUV.y += minimumUV;
        if (encodedUV.y > 1-minimumUV)
            encodedUV.y -= minimumUV;
        
        int radianceMapSize = 16;
        minimumUV = 1.0/radianceMapSize;
        if (encodedUV_.x < minimumUV)
            encodedUV_.x += minimumUV;
        if (encodedUV_.x > 1-minimumUV)
            encodedUV_.x -= minimumUV;
        if (encodedUV_.y < minimumUV)
            encodedUV_.y += minimumUV;
        if (encodedUV_.y > 1-minimumUV)
            encodedUV_.y -= minimumUV;
            
        float2 uv = (float2(texPos) + encodedUV)*float2(1.0/(probeCount.x * probeCount.y), 1.0/probeCount.z);
        float4 d = octahedralMap.sample(s__, uv);
        
        float2 uv_ = (float2(texPos) + encodedUV_)*float2(1.0/(probeCount.x * probeCount.y), 1.0/probeCount.z);
        color_ = radianceMap.sample(s__, uv_).rgb;

        float2 temp = d.rg;
        float mean = temp.x;
        float variance = abs(sq_(temp.x) - temp.y);

        // http://www.punkuser.net/vsm/vsm_paper.pdf; equation 5
        // Need the max in the denominator because biasing can cause a negative displacement
        float chebyshevWeight = variance / (variance + sq_(max(distToProbe - mean, 0.0)));
            
        // Increase contrast in the weight
        chebyshevWeight = max(pow3_(chebyshevWeight), 0.0);

        float finalShadowingWeight = (distToProbe <= mean + depthBias || d.a == 0.0 ) ? 1.0 : chebyshevWeight;
        
//        for (int i = 0; i<9; i++) {
//            color_.r += max(0.0, aCap[i] * probe.shCoeffR[i] * shCoeff[i]);
//            color_.g += max(0.0, aCap[i] * probe.shCoeffG[i] * shCoeff[i]);
//            color_.b += max(0.0, aCap[i] * probe.shCoeffB[i] * shCoeff[i]);
//        }
        color += color_ * trilinearWeights[iCoeff] * finalShadowingWeight;
    //    color += color_ * (1.0/8);
    }
  return color;
}

kernel void shadeKernel(uint2 tid [[thread_position_in_grid]],
                        constant Uniforms_ & uniforms,
                        device Ray *rays,
                        device Ray *shadowRays,
                        device Intersection *intersections,
                        device float3 *vertexColors,
                        device float3 *vertexNormals,
                        device LightProbe *probes,
                        texture2d<float, access::sample> irradianceMap,
                        texture2d<float, access::sample> octahedralMap,
                        texture2d<float, access::sample> radianceMap
                        )
{
  if (tid.x < uniforms.width && tid.y < uniforms.height) {
    unsigned int rayIdx = tid.y * uniforms.width + tid.x;
    device Ray & ray = rays[rayIdx];
    device Ray & shadowRay = shadowRays[rayIdx];
    device Intersection & intersection = intersections[rayIdx];
    float3 color = ray.color;
      shadowRay.indirectColor = 0;
      shadowRay.prevDirection = ray.direction;
    if (ray.maxDistance >= 0.0 && intersection.distance >= 0.0) {
        float3 intersectionPoint = ray.origin + ray.direction * intersection.distance;
        float3 surfaceNormal = interpolateVertexAttribute(vertexNormals,
                                                        intersection);
        surfaceNormal = normalize(surfaceNormal);
        if (dot(surfaceNormal, ray.direction) >= 0) {
            ray.offset = ray.direction * (0.2 + intersection.distance);
            ray.maxDistance = -1.0;
            shadowRay.maxDistance = -1.0;
            return;
        }
        
        float3 lightDirection = uniforms.sunDirection;
        float3 lightColor = uniforms.light.color;
        float lightDistance = INFINITY;
        //    sampleAreaLight(uniforms.light, r, intersectionPoint, lightDirection, lightColor, lightDistance);
        lightColor = saturate(dot(surfaceNormal, lightDirection));
        color = interpolateVertexAttribute(vertexColors, intersection);
        shadowRay.origin = intersectionPoint + surfaceNormal * 1e-3;
        shadowRay.direction = uniforms.sunDirection;
        shadowRay.maxDistance = lightDistance;
        shadowRay.color = 4 * lightColor * color;
  //      shadowRay.color = max((ray.origin);
  //      shadowRay.color = 1;
  //      shadowRay.indirectColor = 1;
  //      shadowRay.color = float3(1, 0.1, 0);
        shadowRay.indirectColor = 0.25 * getDDGI_(shadowRay.origin, surfaceNormal, probes, uniforms.probeData, octahedralMap, radianceMap) * color;
  //      shadowRay.indirectColor = 0.1;
      
  //    float3 sampleDirection = sampleCosineWeightedHemisphere(r);
  //    sampleDirection = alignHemisphereWithNormal(sampleDirection,
  //                                                surfaceNormal);
  //    ray.origin = intersectionPoint + surfaceNormal * 1e-3f;
  //    ray.direction = sampleDirection;
  //    ray.color = color;
        shadowRay.maxDistance = infDist + intersection.distance;
    }
    else {
        ray.maxDistance = -1.0;
        shadowRay.maxDistance = -1.0;
        float3 R = ray.direction;
        R.x = -R.x;
        R.z = -R.z;
        float3 irradiance = irradianceMap.sample(s__, sampleSphericalMap__(R)).rgb;
        irradiance = float3(113, 164, 243)/255;
        shadowRay.indirectColor += irradiance*saturate(dot(ray.direction, float3(0, 1, 0)));
    //    shadowRay.indirectColor = irradiance;
    }
  }
}

kernel void shadowKernel(uint2 tid [[thread_position_in_grid]],
                         device Uniforms_ & uniforms,
                         device Ray *shadowRays,
                         device float *intersections,
                         device LightProbe *probes,
                         texture2d<float, access::write> renderTarget,
                         texture3d<float, access::write> lightProbeTextureR,
                         texture3d<float, access::write> lightProbeTextureG,
                         texture3d<float, access::write> lightProbeTextureB,
                         texture2d<float, access::read_write> octahedralMap) {
    if (tid.x < uniforms.width && tid.y < uniforms.height) {
        unsigned int rayIdx = tid.y * uniforms.width + tid.x;
        device Ray & shadowRay = shadowRays[rayIdx];
        float intersectionDistance = intersections[rayIdx];
        float3 color = 0;
        color += shadowRay.indirectColor;
        float oldValuesR[4] = { 0, 0, 0, 0 };
        float oldValuesG[4] = { 0, 0, 0, 0 };
        float oldValuesB[4] = { 0, 0, 0, 0 };
        if ((shadowRay.maxDistance >= 0.0 && intersectionDistance < 0.0)) {
            color += shadowRay.color;
        }
        int index = tid.x / uniforms.probeWidth;
        int rayDirIndex = tid.y*uniforms.probeWidth + tid.x % uniforms.probeWidth;
        uint2 raycount = uint2(24);
        float3 direction = shadowRay.prevDirection;
        uint2 texPos = indexToTexPos(index, uniforms.probeGridWidth, uniforms.probeGridHeight);
        
        if (shadowRay.maxDistance >= 0) {
            uint2 texPosOcta = texPos * raycount + uint2(octEncode(direction) * float2(raycount));
            float d = shadowRay.maxDistance - infDist;
            float d2 = d*d;
            float4 texColor = octahedralMap.read(texPosOcta);
            int frame = texColor.a;
            float d_before = texColor.r;
            float d_final = (d_before * frame + d)/(frame + 1.0);
            float d2_before = texColor.g;
            float d2_final = (d2_before * frame + d2)/(frame + 1.0);
      //      octahedralMap.write(float4(float3(direction), frame+1), texPosOcta);
            octahedralMap.write(float4(d_final, d2_final, 0, frame+1), texPosOcta);
        }
        
        oldValuesR[0] = direction.x;
        oldValuesR[1] = direction.y;
        oldValuesR[2] = direction.z;
        oldValuesR[3] = color.r;
        
//        oldValuesG[0] = direction.x;
//        oldValuesG[1] = direction.y;
//        oldValuesG[2] = direction.z;
        oldValuesG[3] = color.g;
        
//        oldValuesB[0] = direction.x;
//        oldValuesB[1] = direction.y;
//        oldValuesB[2] = direction.z;
        oldValuesB[3] = color.b;
        
        lightProbeTextureR.write(float4(oldValuesR[0], oldValuesR[1], oldValuesR[2], oldValuesR[3]), ushort3(texPos.x, texPos.y, rayDirIndex));
        
        lightProbeTextureG.write(float4(oldValuesR[3], oldValuesG[3], oldValuesB[3], 1), ushort3(texPos.x, texPos.y, rayDirIndex));
        
    //    lightProbeTextureB.write(float4(oldValuesB[0], oldValuesB[1], oldValuesB[2], oldValuesB[3]), ushort3(texPos.x, texPos.y, rayDirIndex));
    }
}

kernel void accumulateShadowKernel(uint2 tid [[thread_position_in_grid]],
                                   device Uniforms_ & uniforms,
                                   texture2d<float, access::read_write> octahedralMap,
                                   texture2d<float, access::write> depthMap) {
    int shadowProbeReso = 24;
    if (int(tid.x) < uniforms.probeGridWidth * uniforms.probeHeight * shadowProbeReso) {
        int x = tid.x;
        int y = tid.y;
        int kernelSize = 2;
        int2 startI = int2(x - min(kernelSize, x % shadowProbeReso),
                           y - min(kernelSize, y % shadowProbeReso));
        int2 endI = int2(x + min(kernelSize, shadowProbeReso - 1 - x % shadowProbeReso),
                         y + min(kernelSize, shadowProbeReso - 1 - y % shadowProbeReso));
        int nx = (endI.x-startI.x+1)*(endI.y-startI.y+1);
        float sum = 0;
        float sumSquare = 0;
        
//        int2 startI = int2(x - kernelSize/2, y - kernelSize/2);
//        int2 endI = startI + kernelSize;
        
        for(int i = startI.x; i<endI.x; i++) {
            for(int j = startI.y; j<endI.y; j++) {
                float4 d = octahedralMap.read(ushort2(i, j));
                    sum += d.x;
                    sumSquare += d.y;
//                }
            }
        }
        
        sum /= nx;
        sumSquare /= nx;
        float4 d = octahedralMap.read(tid);
        depthMap.write(float4(sum, sumSquare, 0, d.a), tid);
    //    float4 d = octahedralMap.read(tid);
    //    depthMap.write(d, tid);
    }
}

float linearize_depth(float depth) {
    float near = 0.01;
    float far = 100;
    return (far - near)*depth + near;
}

kernel void varianceShadowMapKernel(uint2 tid [[thread_position_in_grid]],
                                   depth2d<float, access::read> shadowMap,
                                   texture2d<float, access::write> varianceShadowMap) {
    if (tid.x < shadowMap.get_width() && tid.y < shadowMap.get_height()) {
        int kernelSize = 4;
        uint2 startI = tid - kernelSize/2;
        uint2 endI = startI + kernelSize;
        uint n = kernelSize * kernelSize;
        float sum = 0;
        float sumSquare = 0;
        
        for(uint i = startI.x; i<endI.x; i++) {
            for(uint j = startI.y; j<endI.y; j++) {
                float d = shadowMap.read(ushort2(i, j));
                d = linearize_depth(d);
                sum += d;
                sumSquare += d * d;
            }
        }
        
        sum /= n;
        sumSquare /= n;
        varianceShadowMap.write(float4(sum, sumSquare, 0, 1), tid);
    }
}

float2 Hammersley_(uint i, float numSamples) {
    uint bits = i;
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
    return float2(i / numSamples, bits / exp2(32.0));
}

#define coprimes float2(2,3)
float2 halton (float2 s)
{
    float4 a = float4(1,1,0,0);
    while (s.x > 0. && s.y > 0.)
    {
        a.xy = a.xy/coprimes;
        a.zw += a.xy * fmod(s, coprimes);
        s = floor(s/coprimes);
    }
    return a.zw;
}

float3 ImportanceSampleGGX_(float2 Xi, float3 N, float roughness)
{
    float a = roughness*roughness;
    
    float phi = 2.0 * PI * Xi.x;
    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a*a - 1.0) * Xi.y));
    float sinTheta = sqrt(1.0 - cosTheta*cosTheta);
    
    // from spherical coordinates to cartesian coordinates - halfway vector
    float3 H;
    H.x = cos(phi) * sinTheta;
    H.y = sin(phi) * sinTheta;
    H.z = cosTheta;
    
    // from tangent-space H vector to world-space sample vector
    float3 up          = abs(N.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent   = normalize(cross(up, N));
    float3 bitangent = cross(N, tangent);
    
    float3 sampleVec = tangent * H.x + bitangent * H.y + N * H.z;
    return normalize(sampleVec);
}

float NormalDistributionGGX_(float NdotH, float roughness) {
    float a2        = roughness * roughness;
    float NdotH2    = NdotH * NdotH;
    
    float nom       = a2;
    float denom     = (NdotH2 * (a2 - 1.0) + 1.0);
    denom           = PI * denom * denom;
    
    return nom / denom;
}

float GeometrySchlickGGX__(float NdotV, float roughness)
{
    // note that we use a different k for IBL
    float a = roughness;
    float k = (a * a) / 2.0;

    float nom   = NdotV;
    float denom = NdotV * (1.0 - k) + k;

    return nom / denom;
}

float GeometrySmith__(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX__(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX__(NdotL, roughness);

    return ggx1 * ggx2;
}

float fresnelSchlick_(float cosTheta)
{
    float F0 = 0.04;
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

float fresnelSchlickRoughness_(float cosTheta, float F0, float roughness) {
    return F0 + (max(float(1.0 - roughness), F0) - F0) * pow(max(1.0 - cosTheta, 0.0), 5.0);
}

kernel void primaryRaysIndirectKernel(
                                uint2 tid [[thread_position_in_grid]],
                                constant Uniforms_ & uniforms [[buffer(2)]],
                                device Ray *rays [[buffer(0)]],
                                constant float3 *eye[[buffer(1)]],
                                texture2d<float, access::sample> normals [[texture(0)]],
                                texture2d<float, access::sample> positions [[texture(1)]],
                                texture2d<float, access::write> reflectedDir [[texture(2)]],
                                depth2d<float, access::sample> noiseTex [[texture(3)]])
{
    uint width = reflectedDir.get_width();
    uint height = reflectedDir.get_height();
    if (tid.x < width && tid.y < height) {
        unsigned int rayIdx = tid.y * width + tid.x;
        device Ray & ray = rays[rayIdx];
        float eps = 0.01;
        float2 uv = (float2(tid))/float2(width, height);
        float3 pos = positions.sample(s_, uv).xyz;
        float3 normal = normals.sample(s_, uv).xyz;
        if (dot(abs(normal), 1) == 0) {
            ray.maxDistance = -1;
            ray.minDistance = 0;
            reflectedDir.write(float4(-1), tid);
            return;
        }
        normal = normalize(normal);
        float3 e = float3(eye->x, eye->y, eye->z);
        float3 v = normalize(e - pos);
        float noise = noiseTex.sample(s__, uv);
        float roughness = max(0.00001, uniforms.roughness.x);
   //     uint largeN = width * height * 100;]
        float2 Xi = halton(uint(1.0/noise * uniforms.frameIndex) % 100000);
        float3 H  = ImportanceSampleGGX_(Xi, normal, roughness);
        float3 r = reflect(-v, H);
//        float dotRN = dot(normal, r);
//        uint numCalcs = 1;
//        while (dotRN < 0 && numCalcs < 1) {
//            numCalcs += 1;
//            Xi = Halton23((rayIdx+1)*numCalcs);
//            H  = ImportanceSampleGGX_(Xi, normal, roughness);
//            r = reflect(v, H);
//            dotRN = dot(normal, r);
//        }
        // F(ω̂ i,ω̂ m)G2(ω̂ i,ω̂ o,ω̂ m)|ω̂ o⋅ω̂ m| /
        //         |ω̂ o⋅ω̂ g||ω̂ m⋅ω̂ g|
        // Wm = h,
        // Wo = v,
        // Wg = n,
        // Wi = l
        
        float NdotH = saturate(dot(normal, H));
        float HdotV = saturate(dot(H, v));
        float NdotV = max(0.001, dot(normal, v));
        float numerator = fresnelSchlickRoughness_(HdotV, 0.04, roughness) * GeometrySmith__(normal, v, r, roughness) * HdotV;
        float denominator = max(0.001, NdotV * NdotH);
        float rayWeight = numerator / denominator;
        
        ray.origin = pos + eps * normal;
        ray.direction = r;
        ray.minDistance = 0.001;
        ray.maxDistance = 100;
        reflectedDir.write(float4(r, rayWeight), tid);
    }
}

kernel void intersectionIndirectKernel(
                                uint2 tid [[thread_position_in_grid]],
                                device Ray *rays,
                                device Intersection *intersections,
                                device float3 *normals,
                                device float3 *colors,
                                texture2d<float, access::write> reflectedPos [[texture(0)]],
                                texture2d<float, access::write> reflectedColors [[texture(1)]])
{
    uint width = reflectedPos.get_width();
    uint height = reflectedPos.get_height();
    if (tid.x < width && tid.y < height) {
        unsigned int rayIdx = tid.y * width + tid.x;
        device Ray & ray = rays[rayIdx];
        device Intersection & intersection = intersections[rayIdx];
        if (ray.maxDistance >= 0.0 && intersection.distance >= 0.0) {
            float3 surfaceNormal = interpolateVertexAttribute(normals,
                                                            intersection);
            float3 albedo = interpolateVertexAttribute(colors, intersection);
            reflectedPos.write(float4(surfaceNormal, intersection.distance), tid);
            reflectedColors.write(float4(albedo, 1.0), tid);
        } else {
            reflectedPos.write(-1, tid);
        }
    }
}
