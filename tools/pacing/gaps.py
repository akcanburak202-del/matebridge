import csv, sys, statistics as st
t=[x for x in csv.DictReader(open(sys.argv[1])) if x['recv_ns'] not in ('','0') and x['capture_us']!='0']
t.sort(key=lambda x:int(x['capture_us']))
rows=[((int(b['capture_us'])-int(a['capture_us']))/1000,(int(b['recv_ns'])-int(a['recv_ns']))/1e6,b) for a,b in zip(t,t[1:])]
cont=[r for r in rows if 15<r[0]<18.5 or 7.5<r[0]<9.2]
big=[r for r in cont if r[1]-r[0]>12]; bunch=[r for r in cont if r[1]<1.0]
dec=[(int(x['decrypted_ns'])-int(x['recv_ns']))/1e6 for x in t]
bigf=[x for x in t if int(x['bytes'])>100000]
print(sys.argv[1],'frames',len(t),'cont',len(cont),'late>12ms',len(big),f'({100*len(big)/max(1,len(cont)):.2f}%)','bunched<1ms',len(bunch),f'({100*len(bunch)/max(1,len(cont)):.2f}%)',
      'decrypt p50/99 ms',round(st.median(dec),3),round(sorted(dec)[int(len(dec)*.99)],3),'keyframes',len(bigf))
