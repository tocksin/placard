"""nvrtc_check.py : syntax-check pfgpu.cu with NVRTC (no GPU needed). pip install nvidia-cuda-nvrtc-cu12"""
import ctypes, glob, os, sys
TOOLS=os.path.dirname(os.path.abspath(__file__))
libs=glob.glob('/usr/local/lib/python3*/dist-packages/nvidia/cuda_nvrtc/lib/libnvrtc.so*')+glob.glob(os.path.expanduser('~/.local/lib/python3*/site-packages/nvidia/cuda_nvrtc/lib/libnvrtc.so*'))+glob.glob('/usr/lib/python3*/site-packages/nvidia/cuda_nvrtc/lib/libnvrtc.so*')
import site
for d in site.getsitepackages()+[site.getusersitepackages()]: libs+=glob.glob(os.path.join(d,'nvidia/cuda_nvrtc/lib/libnvrtc.so*'))
libs=[l for l in libs if 'builtins' not in l]
if not libs: sys.exit('libnvrtc not found')
nv=ctypes.CDLL(libs[0])
src=open(os.path.join(TOOLS,'pfgpu.cu')).read().encode()
prog=ctypes.c_void_p()
r=nv.nvrtcCreateProgram(ctypes.byref(prog),src,b'pfgpu.cu',0,None,None); assert r==0,r
opts=[b'-I'+TOOLS.encode(),b'--std=c++11',b'-arch=compute_89']
arr=(ctypes.c_char_p*len(opts))(*opts)
r=nv.nvrtcCompileProgram(prog,len(opts),arr)
n=ctypes.c_size_t(); nv.nvrtcGetProgramLogSize(prog,ctypes.byref(n)); buf=ctypes.create_string_buffer(n.value); nv.nvrtcGetProgramLog(prog,buf)
print(buf.value.decode() or '(no diagnostics)'); print('compile result',r)
sys.exit(0 if r==0 else 1)
