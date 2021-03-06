# -*- Python -*-

# Return the options to use for a C++ library or binary build.
# Uses the ":optmode" config_setting to pick the options.

load("//tensorflow/core:platform/default/build_config_root.bzl",
     "tf_cuda_tests_tags")

# List of proto files for android builds
def tf_android_core_proto_sources():
    return [
        "//tensorflow/core:example/example.proto",
        "//tensorflow/core:example/feature.proto",
        "//tensorflow/core:framework/allocation_description.proto",
        "//tensorflow/core:framework/attr_value.proto",
        "//tensorflow/core:framework/config.proto",
        "//tensorflow/core:framework/device_attributes.proto",
        "//tensorflow/core:framework/function.proto",
        "//tensorflow/core:framework/graph.proto",
        "//tensorflow/core:framework/kernel_def.proto",
        "//tensorflow/core:framework/op_def.proto",
        "//tensorflow/core:framework/step_stats.proto",
        "//tensorflow/core:framework/summary.proto",
        "//tensorflow/core:framework/tensor.proto",
        "//tensorflow/core:framework/tensor_description.proto",
        "//tensorflow/core:framework/tensor_shape.proto",
        "//tensorflow/core:framework/tensor_slice.proto",
        "//tensorflow/core:framework/types.proto",
        "//tensorflow/core:framework/versions.proto",
        "//tensorflow/core:lib/core/error_codes.proto",
        "//tensorflow/core:protobuf/saver.proto",
        "//tensorflow/core:util/saved_tensor_slice.proto",
  ]


def if_cuda(a, b=[]):
  return select({
      "//third_party/gpus/cuda:cuda_crosstool_condition": a,
      "//conditions:default": b,
  })


def tf_copts():
  return (["-fno-exceptions", "-DEIGEN_AVOID_STL_ARRAY",] +
          if_cuda(["-DGOOGLE_CUDA=1"]) +
          select({"//tensorflow:darwin": [],
                  "//conditions:default": ["-pthread"]}))


# Given a list of "op_lib_names" (a list of files in the ops directory
# without their .cc extensions), generate a library for that file.
def tf_gen_op_libs(op_lib_names):
  # Make library out of each op so it can also be used to generate wrappers
  # for various languages.
  for n in op_lib_names:
    native.cc_library(name=n + "_op_lib",
                      copts=tf_copts(),
                      srcs=["ops/" + n + ".cc"],
                      deps=(["//tensorflow/core:framework"]),
                      visibility=["//visibility:public"],
                      alwayslink=1,
                      linkstatic=1,)


def tf_gen_op_wrapper_cc(name, out_ops_file, pkg=""):
  # Construct an op generator binary for these ops.
  tool = out_ops_file + "_gen_cc"
  native.cc_binary(
      name = tool,
      copts = tf_copts(),
      linkopts = ["-lm"],
      linkstatic = 1,   # Faster to link this one-time-use binary dynamically
      deps = (["//tensorflow/cc:cc_op_gen_main",
               pkg + ":" + name + "_op_lib"])
  )

  # Run the op generator.
  if name == "sendrecv_ops":
    include_internal = "1"
  else:
    include_internal = "0"
  native.genrule(
      name=name + "_genrule",
      outs=[out_ops_file + ".h", out_ops_file + ".cc"],
      tools=[":" + tool],
      cmd=("$(location :" + tool + ") $(location :" + out_ops_file + ".h) " +
           "$(location :" + out_ops_file + ".cc) " + include_internal))


# Given a list of "op_lib_names" (a list of files in the ops directory
# without their .cc extensions), generate individual C++ .cc and .h
# files for each of the ops files mentioned, and then generate a
# single cc_library called "name" that combines all the
# generated C++ code.
#
# For example, for:
#  tf_gen_op_wrappers_cc("tf_ops_lib", [ "array_ops", "math_ops" ])
#
#
# This will ultimately generate ops/* files and a library like:
#
# cc_library(name = "tf_ops_lib",
#            srcs = [ "ops/array_ops.cc",
#                     "ops/math_ops.cc" ],
#            hdrs = [ "ops/array_ops.h",
#                     "ops/math_ops.h" ],
#            deps = [ ... ])
def tf_gen_op_wrappers_cc(name,
                          op_lib_names=[],
                          other_srcs=[],
                          other_hdrs=[],
                          pkg=""):
  subsrcs = other_srcs
  subhdrs = other_hdrs
  for n in op_lib_names:
    tf_gen_op_wrapper_cc(n, "ops/" + n, pkg=pkg)
    subsrcs += ["ops/" + n + ".cc"]
    subhdrs += ["ops/" + n + ".h"]

  native.cc_library(name=name,
                    srcs=subsrcs,
                    hdrs=subhdrs,
                    deps=["//tensorflow/core:core_cpu"],
                    copts=tf_copts(),
                    alwayslink=1,)


# Invoke this rule in .../tensorflow/python to build the wrapper library.
def tf_gen_op_wrapper_py(name, out=None, hidden=[], visibility=None, deps=[],
                         require_shape_functions=False):
  # Construct a cc_binary containing the specified ops.
  tool_name = "gen_" + name + "_py_wrappers_cc"
  if not deps:
    deps = ["//tensorflow/core:" + name + "_op_lib"]
  native.cc_binary(
      name = tool_name,
      linkopts = ["-lm"],
      copts = tf_copts(),
      linkstatic = 1,   # Faster to link this one-time-use binary dynamically
      deps = (["//tensorflow/core:framework",
               "//tensorflow/python:python_op_gen_main"] + deps),
      visibility = ["//tensorflow:internal"],
  )

  # Invoke the previous cc_binary to generate a python file.
  if not out:
    out = "ops/gen_" + name + ".py"

  native.genrule(
      name=name + "_pygenrule",
      outs=[out],
      tools=[tool_name],
      cmd=("$(location " + tool_name + ") " + ",".join(hidden)
           + " " + ("1" if require_shape_functions else "0") + " > $@"))

  # Make a py_library out of the generated python file.
  native.py_library(name=name,
                    srcs=[out],
                    srcs_version="PY2AND3",
                    visibility=visibility,
                    deps=[
                        "//tensorflow/python:framework_for_generated_wrappers",
                    ],)


# Define a bazel macro that creates cc_test for tensorflow.
# TODO(opensource): we need to enable this to work around the hidden symbol
# __cudaRegisterFatBinary error. Need more investigations.
def tf_cc_test(name, deps, linkstatic=0, tags=[], data=[]):
  name = name.replace(".cc", "")
  native.cc_test(name="%s" % (name.replace("/", "_")),
                 srcs=["%s.cc" % (name)],
                 copts=tf_copts(),
                 data=data,
                 deps=deps,
                 linkopts=["-lpthread", "-lm"],
                 linkstatic=linkstatic,
                 tags=tags,)


# Create a cc_test for each of the tensorflow tests listed in "tests"
def tf_cc_tests(tests, deps, linkstatic=0, tags=[]):
  for t in tests:
    tf_cc_test(t, deps, linkstatic, tags=tags)

# Build defs for TensorFlow kernels

# When this target is built using --config=cuda, a cc_library is built
# that passes -DGOOGLE_CUDA=1 and '-x cuda', linking in additional
# libraries needed by GPU kernels.
def tf_gpu_kernel_library(srcs, copts=[], cuda_copts=[], deps=[], hdrs=[],
                          **kwargs):
  cuda_copts = ["-x", "cuda", "-DGOOGLE_CUDA=1",
                "-nvcc_options=relaxed-constexpr", "-nvcc_options=ftz=true",
                "--gcudacc_flag=-ftz=true"] + cuda_copts
  native.cc_library(
      srcs = srcs,
      hdrs = hdrs,
      copts = copts + if_cuda(cuda_copts),
      deps = deps + if_cuda([
          "//tensorflow/core:stream_executor",
      ]) + ["//tensorflow/core/platform/default/build_config:cuda_runtime_extra"],
      alwayslink=1,
      **kwargs)

def tf_cuda_library(deps=None, cuda_deps=None, copts=None, **kwargs):
  """Generate a cc_library with a conditional set of CUDA dependencies.

  When the library is built with --config=cuda:

  - both deps and cuda_deps are used as dependencies
  - the gcudacc runtime is added as a dependency (if necessary)
  - The library additionally passes -DGOOGLE_CUDA=1 to the list of copts

  Args:
  - cuda_deps: BUILD dependencies which will be linked if and only if:
      '--config=cuda' is passed to the bazel command line.
  - deps: dependencies which will always be linked.
  - copts: copts always passed to the cc_library.
  - kwargs: Any other argument to cc_library.
  """
  if not deps:
    deps = []
  if not cuda_deps:
    cuda_deps = []
  if not copts:
    copts = []

  native.cc_library(
      deps = deps + if_cuda(cuda_deps) +
          ["//tensorflow/core/platform/default/build_config:cuda_runtime_extra"],
      copts = copts + if_cuda(["-DGOOGLE_CUDA=1"]),
      **kwargs)


def tf_kernel_library(name, prefix=None, srcs=None, gpu_srcs=None, hdrs=None,
                      deps=None, alwayslink=1, **kwargs):
  """A rule to build a TensorFlow OpKernel.

  May either specify srcs/hdrs or prefix.  Similar to tf_cuda_library,
  but with alwayslink=1 by default.  If prefix is specified:
    * prefix*.cc (except *.cu.cc) is added to srcs
    * prefix*.h (except *.cu.h) is added to hdrs
    * prefix*.cu.cc and prefix*.h (including *.cu.h) are added to gpu_srcs.
  With the exception that test files are excluded.
  For example, with prefix = "cast_op",
    * srcs = ["cast_op.cc"]
    * hdrs = ["cast_op.h"]
    * gpu_srcs = ["cast_op_gpu.cu.cc", "cast_op.h"]
    * "cast_op_test.cc" is excluded
  With prefix = "cwise_op"
    * srcs = ["cwise_op_abs.cc", ..., "cwise_op_tanh.cc"],
    * hdrs = ["cwise_ops.h", "cwise_ops_common.h"],
    * gpu_srcs = ["cwise_op_gpu_abs.cu.cc", ..., "cwise_op_gpu_tanh.cu.cc",
                  "cwise_ops.h", "cwise_ops_common.h", "cwise_ops_gpu_common.cu.h"]
    * "cwise_ops_test.cc" is excluded
  """
  if not srcs:
    srcs = []
  if not hdrs:
    hdrs = []
  if not deps:
    deps = []
  gpu_deps = deps + ["//tensorflow/core:cuda"]

  if prefix:
    if native.glob([prefix + "*.cu.cc"], exclude = ["*test*"]):
      if not gpu_srcs:
        gpu_srcs = []
      gpu_srcs = gpu_srcs + native.glob([prefix + "*.cu.cc", prefix + "*.h"],
                                        exclude = ["*test*"])
    srcs = srcs + native.glob([prefix + "*.cc"],
                              exclude = ["*test*", "*.cu.cc"])
    hdrs = hdrs + native.glob([prefix + "*.h"], exclude = ["*test*", "*.cu.h"])

  cuda_deps = ["//tensorflow/core:gpu_lib"]
  if gpu_srcs:
    tf_gpu_kernel_library(
        name = name + "_gpu",
        srcs = gpu_srcs,
        deps = gpu_deps,
        **kwargs)
    cuda_deps.extend([":" + name + "_gpu"])
  tf_cuda_library(
      name = name,
      srcs = srcs,
      hdrs = hdrs,
      copts = tf_copts(),
      cuda_deps = cuda_deps,
      linkstatic = 1,  # Seems to be needed since alwayslink is broken in bazel
      alwayslink = alwayslink,
      deps = deps,
      **kwargs)


def tf_kernel_libraries(name, prefixes, deps=None, **kwargs):
  """Makes one target per prefix, and one target that includes them all."""
  for p in prefixes:
    tf_kernel_library(name=p, prefix=p, deps=deps, **kwargs)
  native.cc_library(name=name, deps=[":" + p for p in prefixes])


# Bazel rules for building swig files.
def _py_wrap_cc_impl(ctx):
  srcs = ctx.files.srcs
  if len(srcs) != 1:
    fail("Exactly one SWIG source file label must be specified.", "srcs")
  module_name = ctx.attr.module_name
  cc_out = ctx.outputs.cc_out
  py_out = ctx.outputs.py_out
  src = ctx.files.srcs[0]
  args = ["-c++", "-python"]
  args += ["-module", module_name]
  args += ["-l" + f.path for f in ctx.files.swig_includes]
  cc_include_dirs = set()
  cc_includes = set()
  for dep in ctx.attr.deps:
    cc_include_dirs += [h.dirname for h in dep.cc.transitive_headers]
    cc_includes += dep.cc.transitive_headers
  args += ["-I" + x for x in cc_include_dirs]
  args += ["-I" + ctx.label.workspace_root]
  args += ["-o", cc_out.path]
  args += ["-outdir", py_out.dirname]
  args += [src.path]
  outputs = [cc_out, py_out]
  ctx.action(executable=ctx.executable.swig_binary,
             arguments=args,
             mnemonic="PythonSwig",
             inputs=sorted(set([src]) + cc_includes + ctx.files.swig_includes +
                         ctx.attr.swig_deps.files),
             outputs=outputs,
             progress_message="SWIGing {input}".format(input=src.path))
  return struct(files=set(outputs))


_py_wrap_cc = rule(attrs={
    "srcs": attr.label_list(mandatory=True,
                            allow_files=True,),
    "swig_includes": attr.label_list(cfg=DATA_CFG,
                                     allow_files=True,),
    "deps": attr.label_list(allow_files=True,
                            providers=["cc"],),
    "swig_deps": attr.label(default=Label(
        "//tensorflow:swig")),  # swig_templates
    "module_name": attr.string(mandatory=True),
    "py_module_name": attr.string(mandatory=True),
    "swig_binary": attr.label(default=Label("//tensorflow:swig"),
                              cfg=HOST_CFG,
                              executable=True,
                              allow_files=True,),
},
                   outputs={
                       "cc_out": "%{module_name}.cc",
                       "py_out": "%{py_module_name}.py",
                   },
                   implementation=_py_wrap_cc_impl,)


# Bazel rule for collecting the header files that a target depends on.
def _transitive_hdrs_impl(ctx):
  outputs = set()
  for dep in ctx.attr.deps:
    outputs += dep.cc.transitive_headers
  return struct(files=outputs)


_transitive_hdrs = rule(attrs={
    "deps": attr.label_list(allow_files=True,
                            providers=["cc"]),
},
                        implementation=_transitive_hdrs_impl,)


def transitive_hdrs(name, deps=[], **kwargs):
  _transitive_hdrs(name=name + "_gather",
                   deps=deps)
  native.filegroup(name=name,
                   srcs=[":" + name + "_gather"])

def tf_extension_linkopts():
  return []  # No extension link opts

def tf_extension_copts():
  return []  # No extension c opts

def tf_py_wrap_cc(name, srcs, swig_includes=[], deps=[], copts=[], **kwargs):
  module_name = name.split("/")[-1]
  # Convert a rule name such as foo/bar/baz to foo/bar/_baz.so
  # and use that as the name for the rule producing the .so file.
  cc_library_name = "/".join(name.split("/")[:-1] + ["_" + module_name + ".so"])
  extra_deps = []
  _py_wrap_cc(name=name + "_py_wrap",
              srcs=srcs,
              swig_includes=swig_includes,
              deps=deps + extra_deps,
              module_name=module_name,
              py_module_name=name)
  native.cc_binary(
      name=cc_library_name,
      srcs=[module_name + ".cc"],
      copts=(copts + ["-Wno-self-assign", "-Wno-write-strings"]
             + tf_extension_copts()),
      linkopts=tf_extension_linkopts(),
      linkstatic=1,
      linkshared=1,
      deps=deps + extra_deps)
  native.py_library(name=name,
                    srcs=[":" + name + ".py"],
                    srcs_version="PY2AND3",
                    data=[":" + cc_library_name])


def py_tests(name,
             srcs,
             additional_deps=[],
             data=[],
             tags=[],
             shard_count=1,
             prefix=""):
  for src in srcs:
    test_name = src.split("/")[-1].split(".")[0]
    if prefix:
      test_name = "%s_%s" % (prefix, test_name)
    native.py_test(name=test_name,
                   srcs=[src],
                   main=src,
                   tags=tags,
                   visibility=["//tensorflow:internal"],
                   shard_count=shard_count,
                   data=data,
                   deps=[
                       "//tensorflow/python:extra_py_tests_deps",
                       "//tensorflow/python:kernel_tests/gradient_checker",
                   ] + additional_deps,
                   srcs_version="PY2AND3")


def cuda_py_tests(name, srcs, additional_deps=[], data=[], shard_count=1):
  test_tags = tf_cuda_tests_tags()
  py_tests(name, srcs, additional_deps, data, test_tags, shard_count)
