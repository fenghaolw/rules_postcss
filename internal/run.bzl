# Copyright 2019 The Bazel Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""PostCSS run rule.

Runs a internal PostCSS runner, generated via the postcss_gen_runner rule."""

load("@build_bazel_rules_nodejs//:providers.bzl", "run_node")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":plugin.bzl", "PostcssPluginInfo")

ERROR_INPUT_NO_PLUGINS = "No plugins were provided"
ERROR_INPUT_NO_CSS = "Input of one file must be of a .css file"
ERROR_INPUT_TWO_FILES = "Input of two files must be of a .css and .css.map file"
ERROR_INPUT_TOO_MANY = "Input must be up to two files, a .css file, and optionally a .css.map file"

def _run_one(ctx, input_css, input_map, output_css, output_map):
    """Compile a single CSS file to a single output file.

    Returns a list of ouputs generated by this action."""

    if len(ctx.attr.plugins.items()) == 0:
        fail(ERROR_INPUT_NO_PLUGINS)

    # Generate the command line.
    args = ctx.actions.args()
    if ctx.executable.wrapper:
        args.add(ctx.executable.runner.path)
    args.add("--binDir", ctx.bin_dir.path)
    args.add("--cssFile", input_css.path)
    args.add("--outCssFile", output_css.path)

    data = [t.files for t in ctx.attr.data] + [t.files for t in ctx.attr.named_data.keys()]
    for files in data:
        args.add_all("--data", files)

    for (target, name) in ctx.attr.named_data.items():
        for file in target.files.to_list():
            args.add("--namedData", "%s:%s" % (name, file.path))

    if hasattr(ctx.outputs, "additional_outputs"):
        args.add_all("--additionalOutputs", ctx.outputs.additional_outputs)

    if input_map:
        args.add("--cssMapFile", input_map.path)
    if ctx.attr.sourcemap:
        args.add("--outCssMapFile", output_map.path)

    # The command may only access files declared in inputs.
    inputs = depset(
        [input_css] + ([input_map] if input_map else []),
        transitive = data,
    )

    outputs = [output_css]
    if ctx.attr.sourcemap:
        args.add("--sourcemap")
        outputs.append(output_map)

    if hasattr(ctx.outputs, "additional_outputs"):
        outputs.extend(ctx.outputs.additional_outputs)

    plugins = []
    for plugin_key, plugin_options in ctx.attr.plugins.items():
        node_require = plugin_key[PostcssPluginInfo].node_require
        args.add("--pluginRequires", node_require)
        args.add("--pluginArgs", plugin_options if plugin_options else "[]")

    # If a wrapper binary is passed, run it. It gets the actual binary as an
    # input and the path to it as the first arg.
    if ctx.executable.wrapper:
        # If using a wrapper, running as a worker is currently unsupported.
        ctx.actions.run(
            inputs = inputs,
            outputs = outputs,
            executable = ctx.executable.wrapper,
            tools = [ctx.executable.runner],
            arguments = [args],
            progress_message = "Running PostCSS wrapper on %s" % input_css,
        )
    else:
        args.use_param_file("@%s", use_always = True)
        args.set_param_file_format("multiline")
        run_node(
            ctx = ctx,
            inputs = inputs,
            outputs = outputs,
            executable = "runner",
            tools = [],
            arguments = [args],
            progress_message = "Running PostCSS runner on %s" % input_css,
            execution_requirements = {"supports-workers": "1"},
            mnemonic = "PostCSSRunner",
        )

    return outputs

def _postcss_run_impl(ctx):
    # Get the list of files. Fail here if there are more than two files.
    file_list = ctx.files.src
    if len(file_list) > 2:
        fail(ERROR_INPUT_TOO_MANY)

    # Get the .css and .css.map files from the list, which we expect to always
    # contain a .css file, and optionally a .css.map file.
    input_css = None
    input_map = None
    for input_file in file_list:
        if input_file.extension == "css":
            if input_css != None:
                fail(ERROR_INPUT_TWO_FILES)
            input_css = input_file
            continue
        if input_file.extension == "map":
            if input_map != None:
                fail(ERROR_INPUT_TWO_FILES)
            input_map = input_file
            continue
    if input_css == None:
        fail(ERROR_INPUT_NO_CSS)

    outputs = _run_one(
        ctx = ctx,
        input_css = input_css,
        input_map = input_map,
        output_css = ctx.outputs.css_file,
        output_map = ctx.outputs.css_map_file if ctx.attr.sourcemap else None,
    )

    return DefaultInfo(files = depset(outputs), runfiles = ctx.runfiles(files = outputs))

def _postcss_run_outputs(output_name, sourcemap):
    output_name = output_name or "%{name}.css"
    outputs = {"css_file": output_name}
    if sourcemap:
        outputs["css_map_file"] = output_name + ".map"
    return outputs

def _reverse_named_data(names_to_labels):
    """Reverses the named_data parameter from names-to-labels to labels-to-names.

    Bazel only supports a map from labels to strings and not vice-versa, but it
    makes more sense to the user to have names be the keys."""

    labels_to_names = {}
    for (name, label) in names_to_labels.items():
        if label in labels_to_names:
            fail("Values in named_data must be unique. \"%s\" was used twice." % label)
        labels_to_names[label] = name

    return labels_to_names

_postcss_run = rule(
    implementation = _postcss_run_impl,
    attrs = {
        "src": attr.label(
            allow_files = [".css", ".css.map"],
            mandatory = True,
        ),
        "output_name": attr.string(default = ""),
        "additional_outputs": attr.output_list(),
        "sourcemap": attr.bool(default = False),
        "data": attr.label_list(allow_files = True),
        "named_data": attr.label_keyed_string_dict(allow_files = True),
        "plugins": attr.label_keyed_string_dict(
            cfg = "exec",
            mandatory = True,
        ),
        "runner": attr.label(
            executable = True,
            cfg = "host",
            allow_files = True,
            mandatory = True,
        ),
        "wrapper": attr.label(
            executable = True,
            cfg = "host",
            allow_files = True,
        ),
    },
    outputs = _postcss_run_outputs,
)

def postcss_run(named_data = {}, **args):
    _postcss_run(
        named_data = _reverse_named_data(named_data),
        **args
    )

def _postcss_multi_run_impl(ctx):
    # A dict from .css filenames to two-element lists which contain
    # [CSS file, soucemap file]. It's an error for a sourcemap to exist
    # without a CSS file, but not vice versa.
    files_by_name = {}
    for f in ctx.files.srcs:
        if f.extension == "map":
            files_by_name.setdefault(_strip_extension(f.path), [None, None])[1] = f
        else:
            files_by_name.setdefault(f.path, [None, None])[0] = f

    outputs = []
    for (input_css, input_map) in files_by_name.values():
        if not input_css:
            fail("Source map file %s was passed without a corresponding CSS file." % input_map.path)

        output_name = ctx.attr.output_pattern.format(
            name = input_css.basename,
            dir = paths.dirname(input_css.short_path),
            rule = ctx.label.name,
        )

        output_css = ctx.actions.declare_file(output_name)
        output_map = ctx.actions.declare_file(output_name + ".map") if ctx.attr.sourcemap else None

        outputs.extend(_run_one(
            ctx = ctx,
            input_css = input_css,
            input_map = input_map,
            output_css = output_css,
            output_map = output_map,
        ))

    return DefaultInfo(files = depset(outputs), runfiles = ctx.runfiles(files = outputs))

def _strip_extension(path):
    """Removes the final extension from a path."""
    components = path.split(".")
    components.pop()
    return ".".join(components)

_postcss_multi_run = rule(
    implementation = _postcss_multi_run_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".css", ".css.map"],
            mandatory = True,
        ),
        "output_pattern": attr.string(default = "{rule}/{name}"),
        "sourcemap": attr.bool(default = False),
        "data": attr.label_list(allow_files = True),
        "named_data": attr.label_keyed_string_dict(allow_files = True),
        "plugins": attr.label_keyed_string_dict(
            cfg = "exec",
            mandatory = True,
        ),
        "runner": attr.label(
            executable = True,
            cfg = "host",
            allow_files = True,
            mandatory = True,
        ),
        "wrapper": attr.label(
            executable = True,
            cfg = "host",
            allow_files = True,
        ),
    },
)

def postcss_multi_run(named_data = {}, **args):
    _postcss_multi_run(
        named_data = _reverse_named_data(named_data),
        **args
    )
