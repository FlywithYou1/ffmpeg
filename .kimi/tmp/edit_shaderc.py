import codecs
path = '.github/workflows/build-ffmpeg.yml'
with codecs.open(path, 'r', 'utf-8-sig') as f:
    text = f.read()
text = text.replace('ocl-icd-opencl-dev', 'ocl-icd-opencl-dev glslc')
text = text.replace('snappy molten-vk', 'snappy molten-vk shaderc')
text = text.replace('opencl vulkan-headers', 'opencl vulkan-headers shaderc')
text = text.replace('echo "PKG_CONFIG_PATH=$pkgConfigPath" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append', 'echo "PKG_CONFIG_PATH=$pkgConfigPath" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append\n          $shadercTools = "$inst\\tools\\shaderc"\n          if (Test-Path "$shadercTools\\glslc.exe") { echo "$shadercTools" | Out-File $env:GITHUB_PATH -Encoding utf8 -Append; Write-Host "shaderc tools: $shadercTools" }')
with codecs.open(path, 'w', 'utf-8-sig') as f:
    f.write(text)
print('Done')
