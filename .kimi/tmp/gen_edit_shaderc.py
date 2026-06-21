bs = chr(92)
nl = chr(10)

patterns = [
    # Linux apt add glslc
    ('ocl-icd-opencl-dev', 'ocl-icd-opencl-dev glslc'),
    # macOS brew add shaderc
    ('snappy molten-vk', 'snappy molten-vk shaderc'),
    # Windows vcpkg add shaderc
    ('opencl vulkan-headers', 'opencl vulkan-headers shaderc'),
]

# Append shaderc tools dir to PATH in every vcpkg step
old_path_line = 'echo "PKG_CONFIG_PATH=$pkgConfigPath" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append'
new_path_block = (
    'echo "PKG_CONFIG_PATH=$pkgConfigPath" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append' + nl +
    '          $shadercTools = "$inst\\tools\\shaderc"' + nl +
    '          if (Test-Path "$shadercTools\\glslc.exe") { echo "$shadercTools" | Out-File $env:GITHUB_PATH -Encoding utf8 -Append; Write-Host "shaderc tools: $shadercTools" }'
)

out_path = '.kimi/tmp/edit_shaderc.py'
with open(out_path, 'w', encoding='utf-8') as f:
    f.write("import codecs\n")
    f.write("path = '.github/workflows/build-ffmpeg.yml'\n")
    f.write("with codecs.open(path, 'r', 'utf-8-sig') as f:\n")
    f.write("    text = f.read()\n")
    for old, new in patterns:
        f.write(f"text = text.replace({old!r}, {new!r})\n")
    f.write(f"text = text.replace({old_path_line!r}, {new_path_block!r})\n")
    f.write("with codecs.open(path, 'w', 'utf-8-sig') as f:\n")
    f.write("    f.write(text)\n")
    f.write("print('Done')\n")

print(f'Generated {out_path}')
