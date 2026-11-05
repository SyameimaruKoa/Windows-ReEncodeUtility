<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
<Obj RefId="0">
<TN RefId="0">
<T>System.Collections.Hashtable</T>
<T>System.Object</T>
</TN>
<DCT>
<En>
<S N="Key">IsSplitMode</S>
<B N="Value">false</B>
</En>
<En>
<S N="Key">ExternalAudioPrompt</S>
<B N="Value">true</B>
</En>
<En>
<S N="Key">OutputMode</S>
<S N="Value">Subfolder</S>
</En>
<En>
<S N="Key">AfterProcessAction</S>
<S N="Value">None</S>
</En>
<En>
<S N="Key">Metadata</S>
<S N="Value">Ffmpeg</S>
</En>
<En>
<S N="Key">AdditionalArgs</S>
<S N="Value">-metadata:s:v:0 stereo_mode=left_right</S>
</En>
<En>
<S N="Key">AdditionalVF</S>
<S N="Value">split=2[a][b];[a]crop=iw/2:ih:0:0[left];[b]crop=iw/2:ih:iw/2:0[right];[right][left]hstack=inputs=2,setsar=1</S>
</En>
<En>
<S N="Key">Cut</S>
<S N="Value">No</S>
</En>
<En>
<S N="Key">Extension</S>
<S N="Value">mkv</S>
</En>
<En>
<S N="Key">OutputFixedPath</S>
<S N="Value"></S>
</En>
<En>
<S N="Key">EncoderSettings</S>
<Obj N="Value" RefId="1">
<TNRef RefId="0" />
<DCT>
<En>
<S N="Key">Audio</S>
<S N="Value">-c:a copy</S>
</En>
<En>
<S N="Key">AudioType</S>
<S N="Value">copy</S>
</En>
<En>
<S N="Key">Video</S>
<S N="Value">-c:v hevc_qsv -global_quality 25 -preset veryslow</S>
</En>
</DCT>
</Obj>
</En>
</DCT>
</Obj>
</Objs>