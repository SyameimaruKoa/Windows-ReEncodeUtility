<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
<Obj RefId="0">
<TN RefId="0">
<T>System.Collections.Hashtable</T>
<T>System.Object</T>
</TN>
<DCT>
<En>
<S N="Key">TemplateType</S>
<S N="Value">Filter</S>
</En>
<En>
<S N="Key">AdditionalVF</S>
<S N="Value">split=2[left][right];[left]crop=iw/2:ih:0:0,format=gbrp16le[left_eye];[right]crop=iw/2:ih:iw/2:0,format=gbrp16le[right_eye];[left_eye][right_eye]blend=c0_expr=&apos;B&apos;:c1_expr=&apos;B&apos;:c2_expr=&apos;A&apos;,scale=iw*2:ih:flags=lanczos,setsar=1</S>
</En>
<En>
<S N="Key">AdditionalArgs</S>
<S N="Value">-metadata:s:v:0 stereo_mode=mono</S>
</En>
</DCT>
</Obj>
</Objs>
