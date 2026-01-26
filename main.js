// // =======================
// // Initialize jsPsych
// // =======================
const jsPsych = initJsPsych({
  show_progress_bar: true
});

// =======================
// Progress bar helpers
// =======================
function showProgressBar() {
  document.querySelector('#jspsych-progressbar-container').style.display = 'block';
}

function hideProgressBar() {
  document.querySelector('#jspsych-progressbar-container').style.display = 'none';
}

// =======================
// Build master timeline
// =======================
let timeline = [];

// Add phases (order matters)
timeline.push(...instructions_timeline);
timeline.push(...matching_timeline);
timeline.push(...pre_rating_timeline);
timeline.push(trust_game);


// =======================
// Run experiment (ONCE)
// =======================
console.log("Total trials:", timeline.length);
jsPsych.run(timeline);
// =======================
// Initialize jsPsych
// =======================
// const jsPsych = initJsPsych({
//   show_progress_bar: false   // keep hidden by default
// });
//
// // =======================
// // Progress bar helpers
// // =======================
// function showProgressBar() {
//   const bar = document.querySelector('#jspsych-progressbar-container');
//   if (bar) bar.style.display = 'block';
// }
//
// function hideProgressBar() {
//   const bar = document.querySelector('#jspsych-progressbar-container');
//   if (bar) bar.style.display = 'none';
// }
//
// // =======================
// // Get participant ID
// // =======================
// const urlParams = new URLSearchParams(window.location.search);
// const participantID = "F100_F";
// const csvPath = `stimuli/trials/${participantID}.csv`;
//
// // Save ID in data
// // jsPsych.data.addProperties({ participantID });
//
// // =======================
// // Load participant CSV
// // =======================
// // fetch(csvPath)
// //   .then(response => {
// //     if (!response.ok) {
// //       throw new Error("CSV not found for participant: " + participantID);
// //     }
// //     return response.text();
// //   })
// //   .then(text => {
// //
// //     const rows = text.trim().split("\n").slice(1);
// //
// //     const partnerStimuli = rows.map(row => {
// //       const [partner_id, condition, stimulus] = row.split(",");
// //       return { partner_id, condition, stimulus };
// //     });
// //
// //     buildExperiment(partnerStimuli);
// //   })
// //   .catch(err => {
// //     console.error(err);
// //     alert("Experiment loading error. Please contact the researcher.");
// //   });
//
// // =======================
// // Build + run experiment
// // =======================
// function buildExperiment(partnerStimuli) {
//
//   let timeline = [];
//
//   // ---------- Instructions ----------
//   timeline.push(...instructions_timeline);
//
//   // ---------- Matching ----------
//   timeline.push(...matching_timeline);
//
//   // Reveal partners (fake matching)
//   partnerStimuli.forEach(p => {
//     timeline.push({
//       type: jsPsychHtmlKeyboardResponse,
//       stimulus:
//         p.condition === "face"
//           ? `<img src="${p.stimulus}" style="width:250px;">`
//           : `<p style="font-size:32px;">${p.stimulus}</p>`,
//       choices: "NO_KEYS",
//       trial_duration: 1500
//     });
//   });
//
//   // ---------- Trust game ----------
//   const trust_block = {
//     timeline: [trust_trial],
//     timeline_variables: partnerStimuli.map(p => ({ stim: p }))
//   };
//
//   timeline.push(trust_block);
//
//   console.log("Total trials:", timeline.length);
//
//   // 🚀 Run ONCE, at the very end
//   jsPsych.run(timeline);
// }
