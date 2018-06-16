load("@xplat//build_defs:fb_core_android_library.bzl", "fb_core_android_library")
load("@xplat//configurations/buck/android:instrumentation_tests.bzl", "instrumentation_test_ci_config")
load("//buck_imports:redex_utils.bzl", "redex_native_outliner_helper", "escape_path")
load("//native/redex:redex_defs.bzl", "REDEX_ROOT", "REDEX_BINARY", "REDEX_TOOL", "REDEX_LIB", "REDEX_OPT")

REDEX_INSTR_ROOT = "%s/test/instr" % REDEX_ROOT

def redex_instr_test(
    name,
    java_files,
    config,
    java_deps = [],
    proguard_config=None,
    verify_srcs=None,
    gen_dex_artifacts=False,
    native_outlining=False,
    extracted_res_deps=None,
    manifest=None,
):
  deps = java_deps + [
      "//native/fb:fb",
      "//third-party/java/fest:fest",
      "//third-party/java/jsr-305:jsr-305",  ### @Nullable
      "//third-party/java/junit:junit",
      "//third-party/java/testing-support-lib:exposed-instrumentation-api",
      "//third-party/java/testing-support-lib:runner",
  ]
  if native_outlining:
    deps.append("//java/com/facebook/redex:redex")
    deps.append("//libraries/soloader/java/com/facebook/soloader:soloader")

  srcs = list(java_files)
  srcs.append('%s:Utils.java' % REDEX_INSTR_ROOT);

  fb_core_android_library(
    name = name,
    srcs = srcs,
    deps = deps
  )

  if manifest == None:
    manifest = '%s:AndroidManifest.xml' % REDEX_INSTR_ROOT

  native.android_binary(
    name = name + '_non_redex',
    android_sdk_proguard_config = "default",
    manifest = manifest,
    keystore = '//keystores:prod',
    package_type = 'release',
    proguard_config = proguard_config,
    deps = [':' + name],
    aapt_mode = 'aapt2',
  )

  redex_extra_args = []
  redex_extra_args.append('--redex-binary')
  redex_extra_args.append('$(location %s)' % REDEX_BINARY);

  android_binary_name = name + "_redex"
  if native_outlining:
    android_binary_name = name + "_redex_unsigned_pre_so"

  native.android_binary(
    name = android_binary_name,
    android_sdk_proguard_config = "default",
    manifest = manifest,
    keystore = '//keystores:prod',
    package_type = 'release',
    proguard_config = proguard_config,
    redex = True,
    redex_config = config,
    redex_extra_args = redex_extra_args,
    deps = [':' + name],
    aapt_mode = 'aapt2',
  )

  if native_outlining:
    # generate the .so for native outliner and repack the apk
    redex_native_outliner_helper(name + "_redex_unsigned", ['armv7', 'x86'], REDEX_TOOL)
    # resign the repacked apk
    args = "--keystore %s --properties %s" % (
      "$(location //keystores:resign_prod_keystore)",
      "$(location //keystores:resign_prod_keystore_properties)")
    sign_cmd = '$(exe //java/com/facebook/sign:resign_jar) --input $APK --output $OUT %s' % args
    native.apk_genrule(
      name = name + "_redex",
      apk = ':%s' % name + "_redex_unsigned",
      cmd = sign_cmd,
      out = '%s.apk' % name,
    )

  instrumentation_test_ci_config(
    target = ":" + name + "_redex",
  )

  if verify_srcs != None or gen_dex_artifacts:
    # Extract classes.dex from unredex android binary
    native.genrule(
      name = name +'_dex_pre',
      out = 'classes.pre.dex',
      cmd = 'unzip -p $(location :%s_non_redex) classes.dex > $OUT' % name,
    )

    # Extract classes.dex from redex'd android binary
    native.genrule(
      name = name + '_dex_post',
      out = 'classes.post.dex',
      cmd = 'unzip -p $(location :%s_redex) classes.dex > $OUT' % name,
    )

  extracted_res_targets = []
  if extracted_res_deps != None:
    # Extract some non-dex files for verification
    for f in extracted_res_deps:
      escaped = escape_path(f)

      rule_name = '%s_%s_pre' % (name, escaped)
      native.genrule(
        name = rule_name,
        out = escaped,
        cmd = 'unzip -p $(location :%s_non_redex) %s > $OUT' % (name, f),
      )
      extracted_res_targets.append(':' + rule_name)

      rule_name = '%s_%s_post' % (name, escaped)
      native.genrule(
        name = rule_name,
        out = escaped,
        cmd = 'unzip -p $(location :%s_redex) %s > $OUT' % (name, f),
      )
      extracted_res_targets.append(':' + rule_name)

  # For debugging purpose to get dexdump easily.
  if gen_dex_artifacts:
    # dexdump
    native.genrule(
      name = name + '_dex_pre_dump',
      out = 'classes.pre.dex.dump',
      cmd = 'dexdump -d $(location :%s_dex_pre) > $OUT' % name,
    )

    native.genrule(
      name = name + '_dex_post_dump',
      out = 'classes.post.dex.dump',
      cmd = 'dexdump -d $(location :%s_dex_post) > $OUT' % name,
    )

  if verify_srcs != None:
    extracted_res_outputs = ['$(location %s)' % x for x in extracted_res_targets]
    native.cxx_test(
      name = name + '_verify',
      labels = ['no_lsan'],
      srcs = verify_srcs,
      compiler_flags=['-std=gnu++14'],
      env = {
        'dex_pre': '$(location :%s_dex_pre)' % name,
        'dex_post': '$(location :%s_dex_post)' % name,
        'apk': '$(location :%s)' % android_binary_name,
        'extracted_resources': ':'.join(extracted_res_outputs),
      },
      deps = extracted_res_targets + [
        ':%s_dex_post' % name,
        REDEX_LIB,
        REDEX_OPT,
        "xplat//third-party/gmock:gmock",
        '%s:verify-util' % REDEX_INSTR_ROOT
      ],
    )

def redex_test(compiler_flags=[], **kwargs):
  native.cxx_test(
    compiler_flags=compiler_flags+['-std=gnu++14'],
    **kwargs
  )
