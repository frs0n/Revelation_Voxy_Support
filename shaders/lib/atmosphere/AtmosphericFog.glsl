#include "/lib/atmosphere/Rainbow.glsl"
#include "/lib/atmosphere/clouds/Shadows.glsl"

uniform float biomeSandstorm;
uniform float biomeSnowstorm;
uniform float biomeGreenVapor;

//================================================================================================//

// x: Mie y: Rayleigh
const vec2 falloffScale = -1.0 / vec2(12.0, 32.0);

vec2 CalculateFogDensity(in vec3 rayPos, in float uniformFog) {
	rayPos += cameraPosition;

	// float rayLength = length(rayPos + vec3(0.0, planetRadius, 0.0));
	vec2 density = exp2(abs(rayPos.y - VF_HEIGHT) * oms(step(rayPos.y, VF_HEIGHT) * 0.8) * falloffScale);

#if VF_NOISE_QUALITY == LOW
	rayPos.xz -= vec2(1.0, 0.75) * worldTimeCounter;

	float noise = texture(noisetex, rayPos.xz * 0.002).z;
#elif VF_NOISE_QUALITY == MEDIUM
	vec3 windOffset = vec3(0.07, 0.04, 0.05) * worldTimeCounter;

	rayPos *= 0.03;
	rayPos -= windOffset;

	float noise = Pseudo3DNoise(rayPos) * 2.5;
	noise -= Pseudo3DNoise(rayPos * 4.0 - windOffset);
#endif

	density.x *= sqr(noise) * (2.0 + biomeSandstorm * 8.0 + biomeSnowstorm * 4.0);
	density += uniformFog;

	return density * linearstep(cumulusTopAltitude, cumulusBottomAltitude, rayPos.y);
}

//================================================================================================//

#if !defined CLOUD_SHADOWS || defined PASS_SKY_MAP
	#undef VF_CLOUD_SHADOWS
#endif

mat2x3 RaymarchAtmosphericFog(in vec3 startPos, in vec3 endPos, in float dither, in bool skyMask, in uint steps) {
	#if defined DISTANT_HORIZONS
		#define far float(dhRenderDistance)
	#endif

	float rayLength = sdot(endPos - startPos);
	float norm = inversesqrt(rayLength);
	rayLength *= norm;

	vec3 worldDir = (endPos - startPos) * norm;

	// Adaptive step count
	steps = min(steps, uint(float(steps) * 0.4 + rayLength * rcp(16.0)));

	float maxDist = far;
	if (skyMask) {
		// vec2 intersection = RaySphericalShellIntersection(viewerHeight, worldDir.y, planetRadius, cumulusTopRadius);

		// // Not intersecting the volume
		// if (intersection.y < 0.0 || viewerHeight > cumulusBottomRadius) return mat2x3(vec3(0.0), vec3(1.0));

		rayLength = clamp((cumulusTopRadius - viewerHeight) / max0(worldDir.y), 0.0, maxDist);
	}

	float rSteps = rcp(float(steps));

	float stepLength = rayLength * rSteps;
	vec3 rayStep = stepLength * worldDir;
	vec3 rayPos = startPos + rayStep * dither;

	vec3 shadowViewStart = transMAD(shadowModelView, startPos);
	vec3 shadowStart = projMAD(shadowProjection, shadowViewStart);

	vec3 shadowViewStep = mat3(shadowModelView) * rayStep;
	vec3 shadowStep = diagonal3(shadowProjection) * shadowViewStep;
	vec3 shadowPos = shadowStart + shadowStep * dither;

	float LdotV = dot(worldLightVector, worldDir);
	vec2 phase = vec2(AerosolPhase(LdotV), RayleighPhase(LdotV));
	float tyndallStrength = max(VF_TYNDALL_STRENGTH, 1.0);
	float tyndallAmount = tyndallStrength - 1.0;

	// Boost forward Mie scattering to get stronger visible light shafts (Tyndall).
	float forwardPeak = pow8(saturate(LdotV));
	phase.x *= 1.0 + tyndallAmount * (0.6 + 2.0 * forwardPeak);

	float mieDensityMult = VF_MIE_DENSITY * (1.0 + wetness * VF_MIE_DENSITY_RAIN_MULT);

	#ifdef VF_TIME_FADE
		mieDensityMult *= max(wetness, 1.5 - approxSqrt(timeNoon) * 1.5 - timeSunset * 0.75 - timeMidnight * 0.5);
	#endif

	vec3 fogMieExtinction = atmosphereModel.mie_extinction * mieDensityMult;
	vec3 fogMieScattering = atmosphereModel.mie_scattering * mieDensityMult;
	fogMieScattering *= 1.0 + tyndallAmount * 0.75;

	#ifdef PER_BIOME_FOG
		vec3 biomeAlbedo = mix(vec3(1.0), vec3(1.1, 0.9, 0.7), biomeSandstorm);
		biomeAlbedo = mix(biomeAlbedo, vec3(0.95, 1.1, 1.0), biomeGreenVapor);
		fogMieScattering *= biomeAlbedo;
	#endif

	mat2x3 fogExtinctionCoeff = mat2x3(
		fogMieExtinction,
		atmosphereModel.rayleigh_scattering * VF_RAYLEIGH_DENSITY * 0.05
	);

	mat2x3 fogScatteringCoeff = mat2x3(
		fogMieScattering,
		atmosphereModel.rayleigh_scattering * VF_RAYLEIGH_DENSITY * 0.05
	);

	float uniformFog = (16.0 + wetness * VF_MIE_DENSITY_RAIN_MULT * 16.0) / maxDist;

	vec3 scatteringSun = vec3(0.0);
	vec3 scatteringSky = vec3(0.0);
	vec3 transmittance = vec3(1.0);

	for (uint i = 0u; i < steps; ++i, rayPos += rayStep, shadowPos += shadowStep) {
		vec2 stepDensity = CalculateFogDensity(rayPos, uniformFog);

		if (dot(stepDensity, vec2(1.0)) < EPS) continue; // Faster than maxOf()

    #if defined PASS_VOLUMETRIC_FOG
		vec3 shadowScreenPos = DistortShadowSpace(shadowPos) * 0.5 + 0.5;
		#ifdef COLORED_VOLUMETRIC_FOG
			vec3 sampleShadow = vec3(1.0);
			if (saturate(shadowScreenPos) == shadowScreenPos) {
				ivec2 shadowTexel = ivec2(shadowScreenPos.xy * realShadowMapRes);
				sampleShadow = step(shadowScreenPos.z, vec3(texelFetch(shadowtex1, shadowTexel, 0).x));

				float sampleDepth0 = step(shadowScreenPos.z, texelFetch(shadowtex0, shadowTexel, 0).x);
				if (sampleShadow.x != sampleDepth0) {
					vec3 shadowColorSample = pow4(texelFetch(shadowcolor0, shadowTexel, 0).rgb);
					sampleShadow = shadowColorSample * (sampleShadow - sampleDepth0) + vec3(sampleDepth0);
				}
			}
		#else
			float sampleShadow = 1.0;
			if (saturate(shadowScreenPos) == shadowScreenPos) {
				ivec2 shadowTexel = ivec2(shadowScreenPos.xy * realShadowMapRes);
				sampleShadow = step(shadowScreenPos.z, texelFetch(shadowtex1, shadowTexel, 0).x);
			}
		#endif
    #else
        float sampleShadow = 1.0;
    #endif

		#ifdef VF_CLOUD_SHADOWS
			vec2 cloudShadowCoord = WorldToCloudShadowScreenPos(rayPos).xy;

			if (saturate(cloudShadowCoord) == cloudShadowCoord) {
				float cloudShadow = texture(cloudShadowTex, cloudShadowCoord).x;
				sampleShadow *= cloudShadow;
			}
		#endif

		// Raymarch sunlight transmittance
		vec2 opticalDepthSun = vec2(0.0);

		float stepSize = 4.0;
		vec3 lightPos = rayPos;
		for (uint i = 0u; i < 3u; ++i) {
			stepSize *= 1.5;
			lightPos += worldLightVector * stepSize;

			vec2 density = CalculateFogDensity(lightPos, uniformFog);
			opticalDepthSun += density * stepSize;
		}

		// https://zhuanlan.zhihu.com/p/457997155
		vec2 msV = 0.9 * oms(exp2(-8.0 * stepDensity));
		vec2 msEnergy = phase * exp(-opticalDepthSun);
		msEnergy += uniformPhase * msV / (oms(msV) * (1.0 + opticalDepthSun * 0.25));

		vec3 stepExtinction = fogExtinctionCoeff * stepDensity;
		vec3 stepTransmittance = exp(-stepLength * stepExtinction);

		vec3 stepIntegral = transmittance * oms(stepTransmittance) / maxEps(stepExtinction);

		scatteringSun += fogScatteringCoeff * (stepDensity * msEnergy) * stepIntegral * sampleShadow;
		scatteringSky += fogScatteringCoeff * stepDensity * stepIntegral;

		transmittance *= stepTransmittance;

		if (dot(transmittance, vec3(1.0)) < 1e-2) break; // Faster than maxOf()
	}

	#ifndef VF_CLOUD_SHADOWS
		scatteringSun *= 1.0 - wetness * CLOUD_SHADOW_STRENGTH;
	#endif
	scatteringSky *= eyeSkylightSmooth;

	// Apply rainbows
	#ifdef RAINBOWS
		float visibility = wetness * oms(rainStrength);
		if (visibility > EPS) {
			float distanceFade = saturate(rayLength / maxDist) * visibility;
			scatteringSun *= 1.0 + RenderRainbows(LdotV) * distanceFade;
		}
	#endif

	vec3 scattering = scatteringSun * global.directIlluminance;
	scattering += scatteringSky * uniformPhase * global.skyIlluminance;

	return mat2x3(scattering, transmittance);
}
