export const vertexSource = `#version 300 es
in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
`

export const fragmentSource = `#version 300 es
precision highp float;
out vec4 fragColor;
uniform vec2 resolution;
uniform float time;
uniform vec3 camera;
uniform float cloudCover;
uniform float interference;

float hash(vec3 p) {
  p = fract(p * 0.1031);
  p += dot(p, p.yzx + 33.33);
  return fract((p.x + p.y) * p.z);
}
float noise(vec3 p) {
  vec3 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(mix(hash(i), hash(i+vec3(1,0,0)), f.x),
                 mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), f.x), f.y),
             mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), f.x),
                 mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), f.x), f.y), f.z);
}
float fbm(vec3 p) {
  float n = 0.0, a = 0.5;
  for (int i=0; i<5; i++) {
    n += a * noise(p);
    p = p * 2.03 + vec3(5.2, 1.3, 7.1);
    a *= 0.5;
  }
  return n;
}
float peak(vec2 p, vec2 center, vec2 width, float height) {
  vec2 q = (p-center)/width;
  // Uneven radial buttresses break up the silhouette and carve broad gullies.
  vec2 direction = q / max(length(q), .001);
  float buttress = .77 + .34 * noise(vec3(direction*3.4, center.x+13.0));
  return height * exp(-length(q)*1.4/buttress);
}
float terrain(vec2 p) {
  vec2 warp = vec2(noise(vec3(p*.19, 4.0)), noise(vec3(p*.17, 9.0))) - .5;
  vec2 q = p + warp * 1.9;
  float h = peak(q, vec2(0,0), vec2(10,8), 15.0);
  h = max(h, peak(q, vec2(-9,1), vec2(7,6), 11.5));
  h = max(h, peak(q, vec2(8,-3), vec2(7,8), 12.8));
  h = max(h, peak(q, vec2(-5,-10), vec2(8,6), 12.0));
  h = max(h, peak(q, vec2(14,5), vec2(5,7), 8.5));
  float ridge = 1.0-abs(noise(vec3(p*.68, 1.7))*2.0-1.0);
  h += (ridge*1.5 + (noise(vec3(p*1.7, 2.0))-.5)*.75) * smoothstep(.3, 5.0, h);
  return h;
}
float cloudDensity(vec3 p) {
  float envelope = smoothstep(1.0, 2.8, p.y) * (1.0-smoothstep(4.4, 7.4, p.y));
  vec3 wind = vec3(time*.16, 0.0, time*.055);
  float n = fbm((p+wind)*vec3(.19,.34,.19));
  return max(0.0, n - mix(.61,.28,cloudCover)) * envelope * 2.3;
}
vec3 sky(vec3 rd) {
  vec3 col = mix(vec3(.46,.51,.56), vec3(.075,.12,.19), smoothstep(-.12,.7,rd.y));
  vec3 sun = normalize(vec3(-.6,.34,-.7));
  float glow = pow(max(dot(rd,sun),0.0), 9.0);
  col += vec3(.38,.30,.21)*glow;
  col += vec3(.7,.58,.38)*pow(max(dot(rd,sun),0.0), 350.0);
  float wisps = fbm(vec3(rd.xz/max(.12,rd.y)*2.0 + vec2(time*.007,0), 12.0));
  col += .06*smoothstep(.55,.8,wisps)*smoothstep(.0,.4,rd.y);
  return col;
}
void main() {
  vec2 uv = (gl_FragCoord.xy-.5*resolution)/resolution.y;
  vec3 ro = camera;
  vec3 forward = normalize(vec3(0,6.8,0)-ro);
  vec3 right = normalize(cross(forward, vec3(0,1,0)));
  vec3 up = cross(right, forward);
  vec3 rd = normalize(forward*1.5 + right*uv.x + up*uv.y);
  vec3 color = sky(rd);
  float distanceToRock = 100.0;
  float travel = 0.0;
  for (int i=0; i<180; i++) {
    vec3 p = ro+rd*travel;
    float d = p.y-terrain(p.xz);
    if (d < .012*max(1.0,travel*.04)) { distanceToRock = travel; break; }
    travel += max(.025,d*.32);
    if (travel > 95.0) break;
  }
  if (distanceToRock < 95.0) {
    vec3 p = ro+rd*distanceToRock;
    float e=.045;
    vec3 normal = normalize(vec3(terrain(p.xz-vec2(e,0))-terrain(p.xz+vec2(e,0)),
                                2.0*e, terrain(p.xz-vec2(0,e))-terrain(p.xz+vec2(0,e))));
    float light = max(dot(normal,normalize(vec3(-.6,.8,.3))),0.0);
    float snow = hash(floor(p*135.0)+vec3(floor(time*24.0)*19.7));
    float scan = .85+.15*sin(p.y*190.0+floor(time*12.0));
    float value = mix(.28, mix(.035,.94,smoothstep(.2,.8,snow))*scan,interference);
    color = vec3(value)*(.22+light*.85) + vec3(.035,.045,.065);
    color += vec3(.10,.13,.17)*pow(1.0-max(dot(normal,-rd),0.0),3.0);
    color = mix(color,vec3(.42,.48,.54),1.0-exp(-distanceToRock*.008));
  }
  // Integrate the cloud volume only in front of the terrain, so mist wraps
  // around the peaks and correctly occludes their lower slopes.
  float enter = 0.0, leave = min(distanceToRock,85.0);
  if (abs(rd.y) > .0001) {
    float a=(1.0-ro.y)/rd.y, b=(7.4-ro.y)/rd.y;
    enter=max(0.0,min(a,b));
    leave=min(leave,max(a,b));
  }
  float stepSize=max(0.0,leave-enter)/64.0;
  float jitter=hash(vec3(gl_FragCoord.xy, 3.7));
  vec3 cloudLight=vec3(0);
  float transmission=1.0;
  vec3 sun=normalize(vec3(-.6,.8,-.3));
  for (int i=0; i<64; i++) {
    if (stepSize<=0.0 || transmission<.025) break;
    vec3 p=ro+rd*(enter+(float(i)+jitter)*stepSize);
    float density=cloudDensity(p);
    if (density>.001) {
      float shadow=cloudDensity(p+sun*.8)*1.3+cloudDensity(p+sun*2.1)*.7;
      float lighting=exp(-shadow*2.6);
      vec3 shade=mix(vec3(.24,.30,.39), vec3(.94,.91,.84),lighting);
      shade+=vec3(.15,.12,.09)*pow(max(dot(rd,-sun),0.0),6.0);
      float opacity=1.0-exp(-density*stepSize*1.8);
      cloudLight+=transmission*opacity*shade;
      transmission*=1.0-opacity;
    }
  }
  color=color*transmission+cloudLight;
  color=pow(color,vec3(.92));
  vec2 screen=gl_FragCoord.xy/resolution;
  color*=1.0-.26*pow(length((screen-.5)*vec2(1.0,.8)),1.4);
  color+=(hash(vec3(gl_FragCoord.xy,0.0))-.5)*.012;
  fragColor=vec4(color,1);
}
`
