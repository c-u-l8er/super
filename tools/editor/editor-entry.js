import {EditorView, basicSetup} from 'codemirror';
import {EditorState, Compartment} from '@codemirror/state';
import {keymap} from '@codemirror/view';
import {indentWithTab} from '@codemirror/commands';
import {javascript} from '@codemirror/lang-javascript';
import {python} from '@codemirror/lang-python';
import {rust} from '@codemirror/lang-rust';
import {html} from '@codemirror/lang-html';
import {css} from '@codemirror/lang-css';
import {json} from '@codemirror/lang-json';
import {markdown} from '@codemirror/lang-markdown';
import {oneDark} from '@codemirror/theme-one-dark';
function language(path){const ext=path.split('.').at(-1);return ['js','jsx','mjs','cjs','ts','tsx'].includes(ext)?javascript({typescript:['ts','tsx'].includes(ext),jsx:['jsx','tsx'].includes(ext)}):ext==='py'?python():ext==='rs'?rust():['html','htm'].includes(ext)?html():ext==='css'?css():ext==='json'?json():['md','mdx'].includes(ext)?markdown():[];}
export function codeEditor(parent,changed,save){
 const editable=new Compartment();
 const state=(path,doc)=>EditorState.create({doc,extensions:[basicSetup,oneDark,language(path),editable.of(EditorView.editable.of(true)),keymap.of([{key:'Mod-s',run:()=>{save();return true;}},indentWithTab]),EditorView.updateListener.of(u=>{if(u.docChanged)changed(u.state.doc.toString());}),EditorView.theme({'&':{height:'100%',fontSize:'13px',backgroundColor:'#0d1420'},'.cm-scroller':{overflow:'auto',fontFamily:'ui-monospace, monospace'},'.cm-gutters':{backgroundColor:'#0d1420',border:'none',color:'#60728c'},'.cm-content':{padding:'12px 0'},'.cm-activeLine':{backgroundColor:'#17243a'},'.cm-activeLineGutter':{backgroundColor:'#17243a'}})]});
 const view=new EditorView({parent,state:state('', '')});
 return {view,state,show:s=>view.setState(s),current:()=>view.state,text:()=>view.state.doc.toString(),replace:text=>view.dispatch({changes:{from:0,to:view.state.doc.length,insert:text}}),readonly:yes=>view.dispatch({effects:editable.reconfigure(EditorView.editable.of(!yes))})};
}

export {EditorView};
