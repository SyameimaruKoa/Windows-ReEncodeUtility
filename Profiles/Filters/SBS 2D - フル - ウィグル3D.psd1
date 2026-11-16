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
<S N="Value">split=2[left][right];[left]crop=iw/2:ih:0:0[left_eye];[right]crop=iw/2:ih:iw/2:0[right_eye];[left_eye][right_eye]blend=all_expr=&apos;if(lt(mod(T,0.5),0.25),A,B)&apos;,setsar=1</S>
</En>
<En>
<S N="Key">AdditionalArgs</S>
<S N="Value">-metadata:s:v:0 stereo_mode=mono</S>
</En>
</DCT>
</Obj>
</Objs>
