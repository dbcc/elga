package main

VIDEO_SHADER :: `
struct VertexOutput {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

VertexOutput VSMain(uint id : SV_VertexID) {
    VertexOutput output;
    output.uv = float2((id << 1) & 2, id & 2);
    output.position = float4(output.uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return output;
}

Texture2D<float4> video_frame : register(t0);
SamplerState video_sampler : register(s0);

float4 PSNativeRGB(VertexOutput input) : SV_TARGET {
    return float4(video_frame.Sample(video_sampler, input.uv).rgb, 1.0);
}

float4 PSNativeRGBFlipped(VertexOutput input) : SV_TARGET {
    input.uv.y = 1.0 - input.uv.y;
    return float4(video_frame.Sample(video_sampler, input.uv).rgb, 1.0);
}
`
