/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

	Pass: Compute and accumulate volumetric fog

--------------------------------------------------------------------------------
*/

#define PASS_VOLUMETRIC_FOG

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 11 */
out uvec4 packedFogData;

//======// Uniform //=============================================================================//

uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform sampler2D shadowcolor1;

#include "/lib/universal/Uniform.glsl"

//======// SSBO //================================================================================//

#include "/lib/universal/SSBO.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Fetch.glsl"
#include "/lib/universal/Random.glsl"

#include "/lib/lighting/shadow/Common.glsl"

#include "/lib/atmosphere/Common.glsl"
#include "/lib/atmosphere/AtmosphericFog.glsl"

#include "/lib/water/WaterFog.glsl"

const float SKY_VOLUMETRIC_FOG_MIN_DENSITY = 0.30;

mat2x3 UnpackFogData(in uvec3 data) {
	vec2 unpackedZ = unpackHalf2x16(data.z);
	vec3 scattering = vec3(unpackHalf2x16(data.x), unpackedZ.x);
	vec3 transmittance = vec3(unpackUnorm2x16(data.y), unpackedZ.y);
	return mat2x3(scattering, transmittance);
}

//======// Main //================================================================================//
void main() {
    ivec2 texelPos = ivec2(gl_FragCoord.xy * 2.0);

    vec2 screenCoord = gl_FragCoord.xy * viewPixelSize * 2.0;
	vec3 screenPos = vec3(screenCoord, loadDepth0(texelPos));

	vec3 viewPos = ScreenToViewSpace(screenPos);
	#if defined DISTANT_HORIZONS
		if (screenPos.z > 1.0 - EPS) {
			screenPos.z = loadDepth0DH(texelPos);
			viewPos = ScreenToViewSpaceDH(screenPos);
		}
	#endif

	vec3 worldPos = transMAD(gbufferModelViewInverse, viewPos);

	float dither = BlueNoise(texelPos, frameCounter);

	mat2x3 volFogData = mat2x3(vec3(0.0), vec3(1.0));

	#ifdef VOLUMETRIC_FOG
		if (isEyeInWater == 0) {
			volFogData = RaymarchAtmosphericFog(gbufferModelViewInverse[3].xyz, worldPos, dither, screenPos.z > 1.0 - EPS, VF_MAX_SAMPLES);
		}
	#endif
	#ifdef UW_VOLUMETRIC_FOG
		if (isEyeInWater == 1) {
			volFogData = RaymarchWaterFog(worldPos - gbufferModelViewInverse[3].xyz, dither);
		}
	#endif

	// Temporal reprojection
    vec2 prevCoord = Reproject(screenPos).xy;

    if (saturate(prevCoord) == prevCoord && !worldTimeChanged) {
        uvec4 reprojectedData = texelFetch(colortex11, uvToTexel(prevCoord) >> 1, 0);
		mat2x3 reprojectedFog = UnpackFogData(reprojectedData.rgb);

		float blendWeight = 0.9;
		blendWeight *= exp2(abs(uintBitsToFloat(reprojectedData.a) + viewPos.z) * 32.0 / viewPos.z);

        volFogData[0] = mix(volFogData[0], reprojectedFog[0], blendWeight);
        volFogData[1] = mix(volFogData[1], reprojectedFog[1], blendWeight);
	}

	// For sky pixels, suppress very thin volumetric fog to avoid visible noise.
	if (screenPos.z > 1.0 - EPS && isEyeInWater == 0) {
		float fogDensity = 1.0 - mean(volFogData[1]);
		if (fogDensity < SKY_VOLUMETRIC_FOG_MIN_DENSITY) {
			volFogData = mat2x3(vec3(0.0), vec3(1.0));
		}
	}

	packedFogData.x = packHalf2x16(volFogData[0].rg);
	packedFogData.y = packUnorm2x16(volFogData[1].rg);
	packedFogData.z = packHalf2x16(vec2(volFogData[0].b, volFogData[1].b));
	packedFogData.w = floatBitsToUint(-viewPos.z);
}
